// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
import {IConstantsManager} from "../contracts/interfaces/IConstantsManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeeConfig} from "../contracts/interfaces/IFeeConfig.sol";

contract BeefySonicFeesTest is Test {
    BeefySonic public beefySonic;
    BeefySonic public implementation;
    address public want = address(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);
    address public stakingContract = address(0xFC00FACE00000000000000000000000000000000);
    address public beefyFeeRecipient = address(0x02Ae4716B9D5d48Db1445814b0eDE39f5c28264B);
    address public keeper = address(0x4fED5491693007f0CD49f4614FFC38Ab6A04B619);
    address public beefyFeeConfig = address(0x2b0C9702A4724f2BFe7922DB92c4082098533c62);
    address public liquidityFeeRecipient = address(0x10E13f11419165beB0F456eC8a230899E4013BBD);
    uint256 public liquidityFee = 0.1e18;
    string public name = "Beefy Sonic";
    string public symbol = "beS";
    uint256 public beefyValidatorId = 31;

    function setUp() public {
        vm.createSelectFork({urlOrAlias: "sonic", blockNumber: 13732080});
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

        beefySonic.addValidator(beefyValidatorId);
        beefySonic.setValidatorStatus(0, true, true);
    }

    function test_FeeCalculationAndDistribution() public {
        // 1. Initial setup with deposits
        address alice = _deposit(1000e18, "alice");
        
        // 2. Generate rewards through epochs
        _advanceEpoch(2);
        
        // 3. Harvest and verify fee distribution
        uint256 beforeBeefyBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 beforeLiquidityBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        
        beefySonic.harvest();
        
        uint256 afterBeefyBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 afterLiquidityBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        
        assertTrue(afterBeefyBalance > beforeBeefyBalance, "No Beefy fees distributed");
        assertTrue(afterLiquidityBalance > beforeLiquidityBalance, "No liquidity fees distributed");
    }

    function test_FeeConfigurationChanges() public {
        // 1. Initial setup
        address alice = _deposit(1000e18, "alice");
        
        // 2. Change fee configuration
        address newBeefyFeeRecipient = makeAddr("newBeefyFeeRecipient");
        address newLiquidityFeeRecipient = makeAddr("newLiquidityFeeRecipient");
        uint256 newLiquidityFee = 0.05e18;
        
        vm.startPrank(beefySonic.owner());
        beefySonic.setBeefyFeeRecipient(newBeefyFeeRecipient);
        beefySonic.setLiquidityFeeRecipient(newLiquidityFeeRecipient);
        beefySonic.setLiquidityFee(newLiquidityFee);
        vm.stopPrank();
        
        // 3. Generate rewards
        _advanceEpoch(2);
        
        // 4. Verify fees go to new recipients
        uint256 beforeNewBeefyBalance = IERC20(want).balanceOf(newBeefyFeeRecipient);
        uint256 beforeNewLiquidityBalance = IERC20(want).balanceOf(newLiquidityFeeRecipient);
        
        beefySonic.harvest();
        
        uint256 afterNewBeefyBalance = IERC20(want).balanceOf(newBeefyFeeRecipient);
        uint256 afterNewLiquidityBalance = IERC20(want).balanceOf(newLiquidityFeeRecipient);
        
        assertTrue(afterNewBeefyBalance > beforeNewBeefyBalance, "No fees to new Beefy recipient");
        assertTrue(afterNewLiquidityBalance > beforeNewLiquidityBalance, "No fees to new liquidity recipient");
    }

    function test_InvalidFeeConfiguration() public {
        vm.startPrank(beefySonic.owner());
        
        // Test invalid liquidity fee (> 10%)
        vm.expectRevert(IBeefySonic.InvalidLiquidityFee.selector);
        beefySonic.setLiquidityFee(0.11e18);
        
        // Test zero address recipients
        vm.expectRevert(IBeefySonic.ZeroAddress.selector);
        beefySonic.setBeefyFeeRecipient(address(0));
        
        vm.expectRevert(IBeefySonic.ZeroAddress.selector);
        beefySonic.setLiquidityFeeRecipient(address(0));
        
        vm.stopPrank();
    }

    function test_FeeDistributionWithMultipleHarvests() public {
        // 1. Initial setup
        address alice = _deposit(1000e18, "alice");
        
        // 2. First harvest cycle
        _advanceEpoch(2);
        uint256 firstHarvestBeefyBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 firstHarvestLiquidityBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        
        beefySonic.harvest();
        
        uint256 afterFirstHarvestBeefyBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 afterFirstHarvestLiquidityBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        
        // 3. Second harvest cycle
        vm.warp(block.timestamp + 1 days + 1);
        _advanceEpoch(2);
        
        beefySonic.harvest();
        
        uint256 afterSecondHarvestBeefyBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 afterSecondHarvestLiquidityBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        
        // Verify cumulative fee distribution
        assertTrue(
            afterSecondHarvestBeefyBalance - firstHarvestBeefyBalance > 
            afterFirstHarvestBeefyBalance - firstHarvestBeefyBalance,
            "Second harvest Beefy fees not greater than first"
        );
        
        assertTrue(
            afterSecondHarvestLiquidityBalance - firstHarvestLiquidityBalance > 
            afterFirstHarvestLiquidityBalance - firstHarvestLiquidityBalance,
            "Second harvest liquidity fees not greater than first"
        );
    }

    // Helper functions
    function _deposit(uint256 amount, string memory _name) internal returns (address user) {
        user = makeAddr(_name);
        vm.startPrank(user);
        deal(want, user, amount);
        IERC20(want).approve(address(beefySonic), amount);
        beefySonic.deposit(amount, user, user);
        vm.stopPrank();
    }

    function _advanceEpoch(uint256 epochs) internal {
        for (uint256 i = 0; i < epochs; i++) {
            address node = address(0xD100ae0000000000000000000000000000000000);
            vm.startPrank(node);
            uint256 currentEpoch = ISFC(stakingContract).currentEpoch();
            uint256[] memory validators = ISFC(stakingContract).getEpochValidatorIDs(currentEpoch);
            uint256[] memory empty = new uint256[](validators.length);
            uint256[] memory txsFees = new uint256[](validators.length);
            uint256[] memory uptimes = new uint256[](validators.length);
            
            for (uint j = 0; j < validators.length; j++) {
                txsFees[j] = 1 ether;
                uptimes[j] = 1 days;
            }

            ISFC(stakingContract).sealEpoch(empty, empty, uptimes, txsFees);
            ISFC(stakingContract).sealEpochValidators(validators);
            vm.stopPrank();
        }   
    }

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }
} 