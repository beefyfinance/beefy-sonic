// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
import {IConstantsManager} from "../contracts/interfaces/IConstantsManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BeefySonicValidatorsTest
 * @dev Test suite for BeefySonic's validator management functionality
 *
 * This contract tests the validator lifecycle and status management in BeefySonic, including:
 * - Validator addition, deactivation, and reactivation flows
 * - Capacity management and deposit distribution
 * - Offline validator handling and failover mechanisms
 * - Multi-validator operations and interactions
 *
 * Key scenarios covered:
 * 1. Complete validator lifecycle (addition → active → offline → reactivation)
 * 2. Capacity limits and overflow handling
 * 3. Offline validator detection and response
 * 4. Multiple validator coordination and load balancing
 * 5. Validator claims and rewards management
 *
 * The tests ensure proper validator state transitions and maintain
 * system stability during various operational scenarios.
 */
contract BeefySonicValidatorsTest is Test {
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
    uint256 public secondValidatorId = 14;
    uint256 public thirdValidatorId = 13;

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
    }

    function test_ValidatorLifecycle() public {
        // 1. Add validator
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(beefyValidatorId);
        vm.stopPrank();

        // Verify validator was added correctly
        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(0);
        assertEq(validator.id, beefyValidatorId);
        assertTrue(validator.active);
        assertTrue(validator.claim);
        assertEq(validator.delegations, 0);

        // 2. Deactivate validator
        vm.startPrank(beefySonic.owner());
        beefySonic.setValidatorStatus(0, false, false);
        vm.stopPrank();

        // Verify validator status
        validator = beefySonic.validatorByIndex(0);
        assertFalse(validator.active);
        assertFalse(validator.claim);

        // 3. Reactivate validator
        vm.startPrank(beefySonic.owner());
        beefySonic.setValidatorStatus(0, true, true);
        vm.stopPrank();

        // Verify validator status
        validator = beefySonic.validatorByIndex(0);
        assertTrue(validator.active);
        assertTrue(validator.claim);
    }

    function test_ValidatorCapacityManagement() public {
        // 1. Setup validators
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(beefyValidatorId);
        beefySonic.addValidator(secondValidatorId);
        vm.stopPrank();

        // 2. Make deposits to test capacity
        uint256 maxDeposit = beefySonic.maxDeposit(address(this));
        _deposit(maxDeposit, "alice");

        // Verify delegations
        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(1);
        assertGt(validator.delegations, 0, "No delegations to first validator");

        // Try to deposit more than capacity
        address bob = makeAddr("bob");
        vm.startPrank(bob);
        deal(want, bob, maxDeposit + 1e18);
        IERC20(want).approve(address(beefySonic), maxDeposit + 1e18);
        vm.expectRevert();
        beefySonic.deposit(maxDeposit + 1e18, bob, bob);
        vm.stopPrank();
    }

    function test_ValidatorOfflineHandling() public {
        // 1. Setup validator
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(beefyValidatorId);
        vm.stopPrank();

        // 2. Make initial deposit
        _deposit(1000e18, "alice");

        // 3. Simulate validator going offline
        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        // bit indicating offline 1 << 3
        ISFC(stakingContract).deactivateValidator(beefyValidatorId, 1 << 3);
        vm.stopPrank();

        // 4. Try to add same validator again - should revert
        vm.startPrank(beefySonic.owner());
        vm.expectRevert();
        beefySonic.addValidator(beefyValidatorId);
        vm.stopPrank();

        // 5. Add new validator and verify deposits go there
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(secondValidatorId);
        vm.stopPrank();

        _deposit(1000e18, "bob");

        IBeefySonic.Validator memory secondValidator = beefySonic.validatorByIndex(1);
        assertTrue(secondValidator.delegations > 0, "No delegations to second validator");
    }

    function test_MultiValidatorManagement() public {
        // 1. Add multiple validators
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(beefyValidatorId);
        beefySonic.addValidator(secondValidatorId);
        beefySonic.addValidator(thirdValidatorId);
        vm.stopPrank();

        // 2. Verify validator count
        uint256 validatorCount = beefySonic.validatorsLength();
        assertEq(validatorCount, 3, "Incorrect validator count");

        // 3. Test duplicate validator addition
        vm.startPrank(beefySonic.owner());
        vm.expectRevert(IBeefySonic.InvalidValidatorIndex.selector);
        beefySonic.addValidator(beefyValidatorId);
        vm.stopPrank();

        // 4. Test invalid validator status update
        vm.startPrank(beefySonic.owner());
        vm.expectRevert(IBeefySonic.InvalidValidatorIndex.selector);
        beefySonic.setValidatorStatus(99, true, true);
        vm.stopPrank();

        // 5. Test distribution across validators
        uint256 depositAmount = 3000e18;
        _deposit(depositAmount, "alice");

        // Verify distribution
        uint256 totalDelegations = 0;
        for (uint256 i = 0; i < validatorCount; i++) {
            IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(i);
            totalDelegations += validator.delegations;
        }
        assertEq(totalDelegations, depositAmount, "Incorrect total delegations");
    }

    function test_ValidatorClaimManagement() public {
        // 1. Setup validator
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(beefyValidatorId);
        vm.stopPrank();

        // 2. Make deposit and generate rewards
        _deposit(1000e18, "alice");
        _advanceEpoch(2);

        // 3. Test claim management
        vm.startPrank(beefySonic.owner());
        // Disable claiming
        beefySonic.setValidatorStatus(0, true, false);
        vm.stopPrank();

        // Verify no rewards claimed when claim is disabled
        vm.expectRevert(); // not enough rewards
        beefySonic.harvest();

        // Re-enable claiming and verify rewards are claimed
        vm.startPrank(beefySonic.owner());
        beefySonic.setValidatorStatus(0, true, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        _advanceEpoch(2);

        beefySonic.harvest();
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

            for (uint256 j = 0; j < validators.length; j++) {
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
