// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// NOTES: 
/// - 2 redeem requests in same epoch fail (about 10 min) can ddos? 
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
    
    function setUp() public {
        vm.createSelectFork({urlOrAlias: "sonic"});
        implementation = new BeefySonic();
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));

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
        address alice = _deposit(1000e18, "alice");

        assertEq(IERC20(want).balanceOf(alice), 0);
        assertEq(IERC20(address(beefySonic)).balanceOf(address(alice)), 1000e18);
        assertEq(beefySonic.totalAssets(), 1000e18);

        _harvest();
        
        uint256 totalAssets = beefySonic.totalAssets();
        assertEq(totalAssets, 1000e18);

        // Wait for the lock duration
        vm.warp(block.timestamp + 1 days + 1);

        totalAssets = beefySonic.totalAssets();
        assertGt(totalAssets, 1000e18);

        _withdraw(500e18, alice);
        _redeem(500e18, alice);
    }

    function test_multipleUsers() public {
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

    function _withdraw(uint256 sharesAmount, address user) internal {
        vm.startPrank(keeper);
        vm.expectRevert(IBeefySonic.NotAuthorized.selector);
        beefySonic.requestRedeem(sharesAmount, user, user);
        vm.stopPrank();

        vm.startPrank(user);

        uint256 assetAmount = beefySonic.convertToAssets(sharesAmount);
        uint256 requestId = beefySonic.requestRedeem(sharesAmount, user, user);

        vm.expectRevert(IBeefySonic.MinWithdrawNotMet.selector);
        beefySonic.requestRedeem(1e17, user, user);

        vm.expectRevert(IBeefySonic.NotClaimableYet.selector);
        beefySonic.withdraw(requestId, user, user);

        // Wait for the withdrawal
        vm.warp(block.timestamp + 14 days + 1);

        // Mock currentEpoch call on SFC
        _advanceEpoch(4);

        vm.startPrank(user);

        uint256 shares = beefySonic.withdraw(requestId, user, user);
        assertEq(shares, sharesAmount);

        assertEq(IERC20(want).balanceOf(user), assetAmount);
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
