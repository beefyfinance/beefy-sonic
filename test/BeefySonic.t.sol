// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
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

        uint256 len = beefySonic.validatorsLength();
        assertEq(len, 1);

        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(0);
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
        uint256 assetsWithdrawn = beefySonic.emergencyWithdraw(requestId, alice, alice);
        vm.stopPrank();
        
        // 7. Verify that the user received the slashed amount (70% of original)
        uint256 expectedAssets = beefySonic.convertToAssets(500e18) * slashingRefundRatio / 1e18;
        assertApproxEqRel(assetsWithdrawn, expectedAssets, 0.01e18); // Allow 1% deviation
        
        // 8. Verify that the validator is now marked as slashed and inactive
        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(0);
        assertTrue(validator.slashed);
        assertFalse(validator.active);
    }

    function test_MultipleValidators() public {
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(14);
        vm.stopPrank();

        uint256 len = beefySonic.validatorsLength();
        assertEq(len, 2);

        uint256 maxMint = beefySonic.maxMint(address(this));
        console.log("maxMint", maxMint);
        uint256 maxDeposit = beefySonic.maxDeposit(address(this));
        console.log("maxDeposit", maxDeposit);

        address alice = _deposit(maxDeposit, "alice");
        address bob = _deposit(1000e18, "bob");
        address charlie = _deposit(1000e18, "charlie");
        assertEq(beefySonic.balanceOf(alice), maxDeposit);
        assertEq(beefySonic.balanceOf(bob), 1000e18);
        assertEq(beefySonic.balanceOf(charlie), 1000e18);

        _harvest();

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

        vm.stopPrank();
    }

    function _deposit(uint256 amount, string memory _name) internal returns (address user) {
        user = makeAddr(_name);
        vm.startPrank(user);
        deal(want, user, amount);
        IERC20(want).approve(address(beefySonic), amount);
        beefySonic.deposit(amount, user);
        vm.stopPrank();
    }

    function _harvest() internal {
        _advanceEpoch(1);
        beefySonic.harvest();
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
        /// @dev Simulates a user requesting a redeem and then withdrawing the funds.
        /// This test uses a zap contract to simulate the user's operations.
        /// It first tests that the keeper can't make a request,
        /// then it tests that the user can't withdraw before the lock period is over.
        /// Finally, it tests that the user can withdraw the correct amount after the lock period is over.


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
        assertEq(pendingFirstRedeem, sharesAmount - 1e18);

        uint256 pendingSecondRedeem = beefySonic.pendingRedeemRequest(secondRequestId, user);
        assertEq(pendingSecondRedeem, 1e18);

        BeefySonic.RedemptionRequest[] memory requests = beefySonic.userPendingRedeemRequests(user);
        assertEq(requests.length, 2);

        vm.expectRevert(IBeefySonic.NotClaimableYet.selector);
        beefySonic.withdraw(requestId, zap, user);

        // Wait for the withdrawal
        vm.warp(block.timestamp + 14 days + 1);

        // Mock currentEpoch call on SFC
        _advanceEpoch(4);
}
        vm.stopPrank();
       

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
