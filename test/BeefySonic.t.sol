// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
import {IConstantsManager} from "../contracts/interfaces/IConstantsManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// NOTES: 
/// - If a validator is slashed the user who tries to withdraw and gets that validator is punished 

contract BeefySonicTest is Test {
    BeefySonic public beefySonic;
    BeefySonic public implementation;
    address public want = address(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);
    address public stakingContract = address(0xFC00FACE00000000000000000000000000000000);
    address public beefyFeeRecipient = address(0x02Ae4716B9D5d48Db1445814b0eDE39f5c28264B);
    address public keeper = address(0x4fED5491693007f0CD49f4614FFC38Ab6A04B619);
    address public beefyFeeConfig = address(0x2b0C9702A4724f2BFe7922DB92c4082098533c62);
    address public liquidityFeeRecipient = address(0x10E13f11419165beB0F456eC8a230899E4013BBD);
    uint256 public liquidityFee = 0.1e18;
    uint256 public lockDuration;
    string public name = "Beefy Sonic";
    string public symbol = "beS";
    uint256 public beefyValidatorId = 31;
    uint256 public secondValidatorId = 14;
    
    function setUp() public {
        vm.createSelectFork({urlOrAlias: "sonic", blockNumber: 13732080});
        implementation = new BeefySonic();
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));

        vm.expectRevert(IBeefySonic.InvalidLiquidityFee.selector);
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee + 0.1e18,
            name,
            symbol
        );

        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Add validators
        beefySonic.addValidator(beefyValidatorId);

        vm.expectRevert(IBeefySonic.InvalidValidatorIndex.selector);
        beefySonic.addValidator(beefyValidatorId);

        beefySonic.setValidatorActive(0, false);
        beefySonic.setValidatorActive(0, true);

        uint256 len = beefySonic.validatorsLength();
        assertEq(len, 1);

        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(0);
        uint256 decimals = beefySonic.decimals();
        assertEq(decimals, 18);

        address _want = beefySonic.want();
        assertEq(_want, want);

        uint256 withdrawDuration = beefySonic.withdrawDuration();
        uint256 sfcWithdrawDuration = IConstantsManager(ISFC(stakingContract).constsAddress()).withdrawalPeriodTime();
        assertEq(withdrawDuration, sfcWithdrawDuration);

        assertEq(beefySonic.share(), address(beefySonic));

        assertEq(validator.id, beefyValidatorId);
        assertEq(validator.delegations, 0);
        assertEq(validator.active, true);
    }

    function test_DepositHarvestWithdraw() public {
        uint256 depositAmount = 1000e18;

        address alice = _deposit(depositAmount, "alice");

        assertEq(IERC20(want).balanceOf(alice), 0);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(alice)), depositAmount);
        assertEq(beefySonic.totalAssets(), depositAmount);

        _harvest();
        
        uint256 totalAssets = beefySonic.totalAssets();
        assertEq(totalAssets, depositAmount);

        // Wait for the lock duration
        vm.warp(block.timestamp + 1 days + 1);

        totalAssets = beefySonic.totalAssets();
        assertGt(totalAssets, depositAmount);

        _withdraw(depositAmount / 2, alice);
        _redeem(depositAmount / 2, alice);
    }

    function test_MultipleUsers() public {
        address alice = _deposit(1000e18, "alice");
        address bob = _deposit(5000e18, "bob");

        assertEq(IERC20(want).balanceOf(alice), 0);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(alice)), 1000e18);
        assertEq(IERC20(want).balanceOf(bob), 0);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(bob)), 5000e18);
        assertEq(beefySonic.totalAssets(), 6000e18);

        _harvest();

        // Wait for the lock duration
        vm.warp(block.timestamp + 1 days + 1);
        
        uint256 totalAssets = beefySonic.totalAssets();
        assertGt(totalAssets, 6000e18);

        _withdraw(500e18, alice);
        _withdraw(1000e18, bob);
    }

    function test_RedeemAnotherUser() public {
        address alice = _deposit(1000e18, "alice");
        address bob = makeAddr("bob");

        assertEq(IERC20(want).balanceOf(alice), 0);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(alice)), 1000e18);

        vm.startPrank(bob); 
        vm.expectRevert();
        beefySonic.requestRedeem(1000e18, bob, alice);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(alice)), 1000e18);
        vm.stopPrank();
    }

    function test_SlashedValidatorWithdraw() public {
        // 1. First deposit funds with a user
        address alice = _deposit(1000e18, "alice");
        
        // 2. Request a redemption
        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);
        vm.stopPrank();
        
        // 3. Wait for the withdrawal period
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        // Double sign bit indicating bad behavior  1 << 7 = 128
        ISFC(stakingContract).deactivateValidator(beefyValidatorId, 128);
        vm.stopPrank();
        
        // 4. Simulate a validator being slashed before withdrawal
        bool isSlashed = ISFC(stakingContract).isSlashed(beefyValidatorId);
        assertTrue(isSlashed);
        
        // Mock the slashing refund ratio (e.g., 70% of funds can be recovered)
        uint256 slashingRefundRatio = 0.7e18; // 70% refund
        address owner = address(0x69Adb6Bd46852315ADbbfA633d2bbf792CdB3e04);
        vm.startPrank(owner);
        ISFC(stakingContract).updateSlashingRefundRatio(beefyValidatorId, slashingRefundRatio);
        vm.stopPrank();

        // 5. Try normal withdrawal - should revert with WithdrawError
        vm.startPrank(alice);
        vm.expectRevert(IBeefySonic.WithdrawError.selector);
        beefySonic.withdraw(requestId, alice, alice);
        vm.stopPrank();
        
        // 6. Use emergency withdrawal instead
        vm.startPrank(alice);
        beefySonic.emergencyWithdraw(requestId, alice, alice);

        // 7. Request emergency redeem
        uint256 emergencyRedeemId = beefySonic.requestRedeem(100e18, alice, alice, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        vm.startPrank(alice);
        // 8. Withdraw emergency redeem
        beefySonic.withdraw(emergencyRedeemId, alice, alice);
        vm.stopPrank();

        // 9. Verify that the user received the slashed amount (70% of original)
       // uint256 expectedAssets = beefySonic.convertToAssets(600e18) * slashingRefundRatio / 1e18;
       // assertApproxEqRel(emergencyAssets + assetsWithdrawn, expectedAssets, 0.01e18); // Allow 1% deviation

       vm.startPrank(beefySonic.owner());

       beefySonic.addValidator(14);
       beefySonic.checkForSlashedValidatorsAndUndelegate(0);

        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        beefySonic.completeSlashedValidatorWithdraw(0);

        uint256 getRate = beefySonic.getRate();
        console.log("getRateAfterSlashing", getRate);

        uint256 totalAssets = beefySonic.totalAssets();
        console.log("totalAssetsAfterSlashing", totalAssets);

        _harvest();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 rateAfterHarvest = beefySonic.getRate();
        console.log("rateAfterHarvest", rateAfterHarvest);

        uint256 totalAssetsAfterHarvest = beefySonic.totalAssets();
        console.log("totalAssetsAfterHarvest", totalAssetsAfterHarvest);

        vm.stopPrank();

        // 10. Verify that the validator is now marked as slashed and inactive
        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(0);
        assertTrue(validator.slashed);
        assertFalse(validator.active);

        {
            address bob = _deposit(1000e18, "bob");

            _harvest();

            vm.warp(block.timestamp + 1 days + 1);
            
            _withdraw(beefySonic.balanceOf(bob), bob);

            uint256 rateAfterBob = beefySonic.getRate();
            console.log("rateAfterBob", rateAfterBob);

            uint256 totalNewAssets = beefySonic.totalAssets();
            console.log("totalNewAssetsAfterBob", totalNewAssets);
        }
    }

    function test_MultipleValidators() public {
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(14);
        beefySonic.addValidator(13);
        vm.stopPrank();

        uint256 len = beefySonic.validatorsLength();
        assertEq(len, 3);

        uint256 maxMint = beefySonic.maxMint(address(this));
        console.log("maxMint", maxMint);
        uint256 maxDeposit = beefySonic.maxDeposit(address(this));
        console.log("maxDeposit", maxDeposit);

        address alice = _deposit(maxDeposit, "alice");
        address bob = _deposit(1000e18, "bob");

        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        // bit indicating offline 1 << 3
        ISFC(stakingContract).deactivateValidator(beefyValidatorId, 1 << 3);
        vm.stopPrank();

        address charlie = _deposit(1000e18, "charlie");
        assertEq(beefySonic.balanceOf(alice), maxDeposit);
        assertEq(beefySonic.balanceOf(bob), 1000e18);
        assertEq(beefySonic.balanceOf(charlie), 1000e18);

        _harvest();
        uint256 locked = beefySonic.lockedProfit();
        console.log("lockedProfit", locked);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 ppfs = beefySonic.getPricePerFullShare();
        console.log("ppfs", ppfs);
        uint256 rate = beefySonic.getRate();
        console.log("rate", rate);

        uint256 totalAssets = beefySonic.totalAssets();
        console.log("totalAssets", totalAssets);

        // try to withdraw via 2 validators
        _withdraw(3000e18, alice);
        _withdraw(beefySonic.balanceOf(alice), alice);
        _withdraw(beefySonic.balanceOf(bob), bob);
        _withdraw(beefySonic.balanceOf(charlie), charlie);

        /// Should have earned rewards
        assertGt(IERC20(want).balanceOf(alice), maxDeposit);
        assertGt(IERC20(want).balanceOf(bob), 1000e18);
        assertGt(IERC20(want).balanceOf(charlie), 1000e18);
    }

    function test_MultipleWithdraw() public {
        address alice = _deposit(1000e18, "alice");
        _withdrawMultiple(1000e18, alice);
    }

    function test_Setters() public {
        vm.startPrank(beefySonic.owner());

        beefySonic.setLiquidityFeeRecipient(address(0x1234567890123456789012345678901234567890));
        assertEq(beefySonic.liquidityFeeRecipient(), address(0x1234567890123456789012345678901234567890));

        vm.expectRevert(IBeefySonic.InvalidLiquidityFee.selector);
        beefySonic.setLiquidityFee(0.11e18);

        beefySonic.setLiquidityFee(0.05e18);
        assertEq(beefySonic.liquidityFee(), 0.05e18);

        beefySonic.setBeefyFeeConfig(address(0x1234567890123456789012345678901234567890));
        assertEq(beefySonic.beefyFeeConfig(), address(0x1234567890123456789012345678901234567890));

        beefySonic.setBeefyFeeRecipient(address(0x1234567890123456789012345678901234567890));
        assertEq(beefySonic.beefyFeeRecipient(), address(0x1234567890123456789012345678901234567890));

        beefySonic.setKeeper(address(0x1234567890123456789012345678901234567890));
        assertEq(beefySonic.keeper(), address(0x1234567890123456789012345678901234567890));

        beefySonic.setLockDuration(2 days);
        assertEq(beefySonic.lockDuration(), 2 days);

        beefySonic.setMinHarvest(10e18);
        assertEq(beefySonic.minHarvest(), 10e18);

        beefySonic.setKeeper(address(0x1234567890123456789012345678901234567890));
        assertEq(beefySonic.keeper(), address(0x1234567890123456789012345678901234567890));

        address newImpl = address(new BeefySonic());
        beefySonic.upgradeToAndCall(newImpl, new bytes(0));

        vm.expectRevert(IBeefySonic.ERC7540AsyncFlow.selector);
        beefySonic.previewRedeem(1000e18);

        vm.expectRevert(IBeefySonic.ERC7540AsyncFlow.selector);
        beefySonic.previewWithdraw(1000e18);

        beefySonic.setValidatorClaim(0, true);

        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        // bit indicating offline 1 << 3
        ISFC(stakingContract).deactivateValidator(15, 1 << 3);
        vm.stopPrank();

        vm.startPrank(beefySonic.owner());

        vm.expectRevert(IBeefySonic.NotOK.selector);
        beefySonic.addValidator(15);

        vm.expectRevert(IBeefySonic.InvalidValidatorIndex.selector);
        beefySonic.setValidatorActive(15, true);

        assertEq(beefySonic.supportsInterface(0x620ee8e4), true);
        assertEq(beefySonic.supportsInterface(0x2f0a18c5), true);
        assertEq(beefySonic.supportsInterface(0xe3bc4e65), true);

        vm.stopPrank();
    }

    function _deposit(uint256 amount, string memory _name) internal returns (address user) {
        user = makeAddr(_name);
        vm.startPrank(user);
        deal(want, user, amount);
        IERC20(want).approve(address(beefySonic), amount);

        vm.expectRevert(IBeefySonic.ZeroDeposit.selector);
        beefySonic.deposit(0, user);

        uint256 shares = beefySonic.previewDeposit(amount / 2);
        uint256 assetAmount = beefySonic.mint(shares, user, user);

        uint256 bal = amount - assetAmount;

        vm.expectRevert(IBeefySonic.ZeroAddress.selector);
        beefySonic.deposit(bal, address(0), user);

        beefySonic.deposit(bal, user, user);
        vm.stopPrank();
    }

    function _harvest() internal {
        address random = makeAddr("random");
        vm.startPrank(random);

        vm.expectRevert(IBeefySonic.NotAuthorized.selector);
        beefySonic.pause();
        vm.stopPrank();

        vm.startPrank(keeper);
        beefySonic.pause();

        vm.expectRevert();
        beefySonic.harvest();

        vm.stopPrank();

        vm.startPrank(beefySonic.owner());
        beefySonic.unpause();
        _advanceEpoch(1);
        beefySonic.harvest();

        _advanceEpoch(1);

        vm.expectRevert(IBeefySonic.NotReadyForHarvest.selector);
        beefySonic.harvest();
        vm.stopPrank();
    }

    function _advanceEpoch(uint256 epochs) internal {
        for (uint256 i = 0; i < epochs; i++) {
            address node = address(0xD100ae0000000000000000000000000000000000);
            vm.startPrank(node);
            uint256 currentEpoch = ISFC(stakingContract).currentEpoch();
            uint256[] memory validators = ISFC(stakingContract).getEpochValidatorIDs(currentEpoch);

            uint256[] memory empty = new uint256[](validators.length);

            // Generate some transaction fees to create rewards
            uint256[] memory txsFees = new uint256[](validators.length);
            for (uint j = 0; j < validators.length; j++) {
                txsFees[j] = 1 ether; // Add some transaction fees for each validator
            }

            // Seal epoch with transaction fees and 100% uptime
            uint256[] memory uptimes = new uint256[](validators.length);
            for (uint j = 0; j < validators.length; j++) {
                uptimes[j] = 1 days; // Assuming 1 day epoch duration
            }

            ISFC(stakingContract).sealEpoch(empty, empty, uptimes, txsFees);
            ISFC(stakingContract).sealEpochValidators(validators);
            vm.stopPrank();
        }   
    }

     function _advanceEpochOffline(uint256 epochs) internal {
        for (uint256 i = 0; i < epochs; i++) {
            address node = address(0xD100ae0000000000000000000000000000000000);
            vm.startPrank(node);
            uint256 currentEpoch = ISFC(stakingContract).currentEpoch();
            uint256[] memory validators = ISFC(stakingContract).getEpochValidatorIDs(currentEpoch);

            uint256[] memory empty = new uint256[](validators.length);

            // Generate some transaction fees to create rewards
            uint256[] memory txsFees = new uint256[](validators.length);
            for (uint j = 0; j < validators.length; j++) {
                if (validators[j] == beefyValidatorId) txsFees[j] = 0;
                else txsFees[j] = 1 ether; // Add some transaction fees for each validator
            }

            // Seal epoch with transaction fees and 100% uptime
            uint256[] memory uptimes = new uint256[](validators.length);
            for (uint j = 0; j < validators.length; j++) {
                if (validators[j] == beefyValidatorId) uptimes[j] = 0;
                else uptimes[j] = 1 days; // Assuming 1 day epoch duration
            }

            ISFC(stakingContract).sealEpoch(empty, empty, uptimes, txsFees);
            ISFC(stakingContract).sealEpochValidators(validators);
            vm.stopPrank();
        }   
    }

    function _withdrawMultiple(uint256 sharesAmount, address user) internal {
        vm.startPrank(user);

        uint256[] memory requestIds = new uint256[](2);
        uint256 halfShares = sharesAmount / 2;
        uint256 requestId = beefySonic.requestRedeem(halfShares, user, user);
        uint256 secondRequestId = beefySonic.requestRedeem(sharesAmount - halfShares, user, user);
        requestIds[0] = requestId;
        requestIds[1] = secondRequestId;

        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        vm.startPrank(user);

        uint256 shares = beefySonic.withdraw(requestIds, user, user);
        assertEq(shares, sharesAmount);

        vm.stopPrank();
    }

    function _withdraw(uint256 sharesAmount, address user) internal {
        vm.startPrank(keeper);
        vm.expectRevert(IBeefySonic.NotAuthorized.selector);
        beefySonic.requestRedeem(sharesAmount, user, user);
        vm.stopPrank();

        address zap = makeAddr("zap");

        vm.startPrank(user);
        beefySonic.setOperator(zap, true);
        vm.stopPrank();

       vm.startPrank(zap);

        uint256 before = IERC20(want).balanceOf(user);
        uint256 assetAmount = beefySonic.convertToAssets(sharesAmount - 1e18);
        uint256 secondAssetAmount = beefySonic.convertToAssets(1e18);
        uint256 requestId = beefySonic.requestRedeem(sharesAmount - 1e18, zap, user);
        uint256 secondRequestId = beefySonic.requestRedeem(1e18, zap, user);
{
        uint256 pendingFirstRedeem = beefySonic.pendingRedeemRequest(requestId, user);
        uint256 zeroClaim = beefySonic.claimableRedeemRequest(requestId, user);
        assertEq(zeroClaim, 0);
        assertEq(pendingFirstRedeem, sharesAmount - 1e18);

        uint256 pendingSecondRedeem = beefySonic.pendingRedeemRequest(secondRequestId, user);
        assertEq(pendingSecondRedeem, 1e18);

        BeefySonic.RedemptionRequest[] memory requests = beefySonic.userPendingRedeemRequests(user);
        assertEq(requests.length, 2);

        bool isOperator = beefySonic.isOperator(user, zap);
        assertEq(isOperator, true);

        vm.expectRevert(IBeefySonic.NotClaimableYet.selector);
        beefySonic.withdraw(requestId, zap, user);

        // Wait for the withdrawal
        vm.warp(block.timestamp + 14 days + 1);

        // Mock currentEpoch call on SFC
        _advanceEpoch(4);
}
        vm.stopPrank();
       
{
        vm.startPrank(user);

        uint256 claimableRedeem = beefySonic.claimableRedeemRequest(requestId, user);
        uint256 pendingRedeem = beefySonic.pendingRedeemRequest(requestId, user);
        assertEq(pendingRedeem, 0);
        assertEq(claimableRedeem, sharesAmount - 1e18);

        uint256 secondClaimableRedeem = beefySonic.claimableRedeemRequest(secondRequestId, user);
        assertEq(secondClaimableRedeem, 1e18);

        uint256 shares = beefySonic.withdraw(requestId, user, user);
        assertEq(shares, sharesAmount - 1e18);
        uint256 secondShares = beefySonic.withdraw(secondRequestId, user, user);
        assertEq(secondShares, 1e18);

        assertEq(IERC20(want).balanceOf(user) - before, assetAmount + secondAssetAmount);
        vm.stopPrank();
    }   
    }

    function _redeem(uint256 sharesAmount, address user) internal { 
        vm.startPrank(user);

        uint256 assetAmount = beefySonic.convertToAssets(sharesAmount);
       
        _advanceEpoch(1);

        vm.startPrank(user);
        uint256 requestId = beefySonic.requestRedeem(sharesAmount, user, user);

        vm.expectRevert(IBeefySonic.NotClaimableYet.selector);
        beefySonic.redeem(requestId, user, user);

        // Wait for the withdrawal
        vm.warp(block.timestamp + 14 days + 1);

        // Mock currentEpoch call on SFC
        _advanceEpoch(4);
        vm.startPrank(user);

        uint256 before = IERC20(want).balanceOf(user);

        uint256 assets = beefySonic.redeem(requestId, user, user);
        assertEq(assets, assetAmount);

        assertEq(IERC20(want).balanceOf(user), before + assetAmount);
        vm.stopPrank();
    }

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }
  
}
