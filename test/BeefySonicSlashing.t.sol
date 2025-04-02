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
 * @title BeefySonicSlashingTest
 * @dev Test suite for BeefySonic's slashing recovery mechanisms
 *
 * This contract tests the slashing recovery functionality in BeefySonic, including:
 * - Partial and complete slashing scenarios
 * - Recovery fund calculation and distribution
 * - Emergency withdrawal procedures
 * - Multi-validator slashing events
 *
 * Key scenarios covered:
 * 1. Partial slashing with various refund ratios
 * 2. Complete slashing with zero refund
 * 3. Recovery fund redistribution to active validators
 * 4. Emergency withdrawals after slashing
 * 5. Multiple validator slashing coordination
 *
 * The tests utilize the Sonic fork and simulate slashing events
 * through the SFC contract to verify proper handling and accounting.
 */
contract BeefySonicSlashingTest is Test {
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

    uint256 internal constant DOUBLESIGN_BIT = 1 << 7;
    uint256 internal constant CHEATER_MASK = DOUBLESIGN_BIT;
    uint256 internal constant SLASHED_STATUS = 1 << 7;

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

    function test_SlashingRecoveryWithPartialRefund() public {
        // 1. Initial deposit and setup
        address alice = _deposit(1000e18, "alice");

        // 2. Request redemption for half the amount
        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);
        vm.stopPrank();

        // 3. Simulate validator being slashed with 70% refund ratio
        _simulateSlashing(beefyValidatorId, 0.7e18);

        // 4. Try normal withdrawal - should revert
        vm.startPrank(alice);
        vm.expectRevert(IBeefySonic.WithdrawError.selector);
        beefySonic.withdraw(requestId, alice, alice);
        vm.stopPrank();

        // 5. Process emergency withdrawal
        vm.startPrank(alice);
        uint256 beforeBalance = IERC20(want).balanceOf(alice);
        beefySonic.emergencyWithdraw(requestId, alice, alice);
        uint256 afterBalance = IERC20(want).balanceOf(alice);

        // Should receive ~70% of requested amount
        assertApproxEqRel(afterBalance - beforeBalance, (500e18 * 0.7e18) / 1e18, 0.01e18);
        vm.stopPrank();
    }

    function test_SlashingRecoveryWithZeroRefund() public {
        // 1. Initial deposit
        address alice = _deposit(1000e18, "alice");

        // 2. Request redemption
        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);
        vm.stopPrank();

        // 3. Simulate validator being slashed with 0% refund
        _simulateSlashing(beefyValidatorId, 0);

        // 4. Emergency withdrawal should revert due to no recoverable amount
        vm.startPrank(alice);
        vm.expectRevert();
        beefySonic.emergencyWithdraw(requestId, alice, alice);
        vm.stopPrank();
    }

    function test_SlashingRecoveryAndRedistribution() public {
        // 1. Setup with multiple validators
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(secondValidatorId);
        vm.stopPrank();

        // 2. Initial deposits
        _deposit(1000e18, "alice");

        // 3. Slash first validator
        _simulateSlashing(beefyValidatorId, 0.7e18);

        // 4. Process slashing recovery
        vm.startPrank(beefySonic.owner());
        beefySonic.checkForSlashedValidatorsAndUndelegate(0);

        // Advance time for withdrawal period
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        // Complete slashed validator withdrawal
        beefySonic.completeSlashedValidatorWithdraw(0);
        vm.stopPrank();

        // 5. Verify redistribution to second validator
        IBeefySonic.Validator memory validator = beefySonic.validatorByIndex(1);
        assertTrue(validator.delegations > 0, "Funds not redistributed to second validator");
    }


    function test_SlashedThenDeposit() public {
         // Setup multiple validators
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(secondValidatorId);
        beefySonic.addValidator(13); // Third validator
        vm.stopPrank();

        // Initial deposits
        _deposit(3000e18, "alice");

        // Slash first validator
        _simulateSlashing(beefyValidatorId, 0.7e18);

        // Should revert due to slashed validator
        address user = makeAddr("bob");
        vm.startPrank(user);
        deal(want, user, 1000e18);
        IERC20(want).approve(address(beefySonic), 1000e18);
        vm.expectRevert(IBeefySonic.SlashNotRealized.selector);
        beefySonic.deposit(1000e18, user, user);
        vm.stopPrank();

        // Process slashing recovery
        vm.startPrank(beefySonic.owner());
        beefySonic.checkForSlashedValidatorsAndUndelegate(0);

        // Advance time for withdrawal period
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        // Complete slashed validator withdrawal
        beefySonic.completeSlashedValidatorWithdraw(0);
        vm.stopPrank();

        bool isActive = beefySonic.validatorByIndex(0).active;
        assertFalse(isActive, "Validator should be inactive after recovery");

        // Should not revert due to slashed validator
        _deposit(1000e18, "bob");
    }

    function test_MultipleSlashingScenarios() public {
        // Setup multiple validators
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(secondValidatorId);
        beefySonic.addValidator(13); // Third validator
        vm.stopPrank();

        // Initial deposits
        _deposit(3000e18, "alice");

        // Slash validators with different refund ratios
        _simulateSlashing(beefyValidatorId, 0.7e18);
        _simulateSlashing(secondValidatorId, 0.5e18);

        // Process recovery for each validator
        vm.startPrank(beefySonic.owner());
        beefySonic.checkForSlashedValidatorsAndUndelegate(0);
        beefySonic.checkForSlashedValidatorsAndUndelegate(1);

        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        beefySonic.completeSlashedValidatorWithdraw(0);
        beefySonic.completeSlashedValidatorWithdraw(1);
        vm.stopPrank();

        // Verify final state
        IBeefySonic.Validator memory lastValidator = beefySonic.validatorByIndex(2);
        assertTrue(lastValidator.active, "Last validator should remain active");
        assertTrue(lastValidator.delegations > 0, "Recovered funds not redistributed");
    }

    function test_ComplexSlashingRecoveryWithFees() public {
        // Setup multiple validators with different amounts
        uint256 thirdValidatorId = 13;
        vm.startPrank(beefySonic.owner());
        beefySonic.addValidator(secondValidatorId);
        beefySonic.addValidator(thirdValidatorId);
        beefySonic.setValidatorStatus(1, true, true);
        beefySonic.setValidatorStatus(2, true, true);
        vm.stopPrank();

        // Make deposits from multiple users
        address alice = _deposit(3000e18, "alice");
        address bob = _deposit(2000e18, "bob");

        // Record initial balances
        uint256 initialBeefyFeeBalance = IERC20(want).balanceOf(beefyFeeRecipient);
        uint256 initialLiquidityFeeBalance = IERC20(want).balanceOf(liquidityFeeRecipient);
        uint256 initialStoredTotal = beefySonic.totalAssets();

        // Create redemption requests with different amounts
        vm.startPrank(alice);
        uint256 request1 = beefySonic.requestRedeem(1500e18, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 request2 = beefySonic.requestRedeem(1000e18, bob, bob);
        vm.stopPrank();

        // Simulate different slashing scenarios
        _simulateSlashing(beefyValidatorId, 0.7e18); // 70% refund
        _simulateSlashing(secondValidatorId, 0.3e18); // 30% refund

        // Process recovery for both validators
        vm.startPrank(beefySonic.owner());
        beefySonic.checkForSlashedValidatorsAndUndelegate(0);
        beefySonic.checkForSlashedValidatorsAndUndelegate(1);

        // Advance time for withdrawal period
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        // harvest
        beefySonic.harvest();

        address charlie = makeAddr("charlie");
        deal(want, charlie, 1000e18);
        vm.startPrank(charlie);

        IERC20(want).approve(address(beefySonic), 1000e18);

        vm.expectRevert(IBeefySonic.SlashNotRealized.selector);
        beefySonic.deposit(1000e18, charlie, charlie);
        vm.stopPrank();

        vm.startPrank(beefySonic.owner());

        // Complete slashed validator withdrawals
        uint256 recoveredAmount = 0;
        recoveredAmount += beefySonic.completeSlashedValidatorWithdraw(0);
        recoveredAmount += beefySonic.completeSlashedValidatorWithdraw(1);
        vm.stopPrank();

        // Process emergency withdrawals
        vm.startPrank(alice);
        uint256 aliceBeforeBalance = IERC20(want).balanceOf(alice);
        beefySonic.emergencyWithdraw(request1, alice, alice);
        uint256 aliceRecovered = IERC20(want).balanceOf(alice) - aliceBeforeBalance;
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobBeforeBalance = IERC20(want).balanceOf(bob);
        beefySonic.emergencyWithdraw(request2, bob, bob);
        uint256 bobRecovered = IERC20(want).balanceOf(bob) - bobBeforeBalance;
        vm.stopPrank();

        // Verify fee distributions
        uint256 beefyFeeCharged = IERC20(want).balanceOf(beefyFeeRecipient) - initialBeefyFeeBalance;
        uint256 liquidityFeeCharged = IERC20(want).balanceOf(liquidityFeeRecipient) - initialLiquidityFeeBalance;

        assertTrue(beefyFeeCharged > 0, "Beefy fees should be charged");
        assertTrue(liquidityFeeCharged > 0, "Liquidity fees should be charged");

        // Calculate expected fees (10% liquidity fee)
        uint256 expectedLiquidityFee = 486997347496628500;
        assertApproxEqRel(liquidityFeeCharged, expectedLiquidityFee, 0.0001e18, "Liquidity fee should be ~10%");

        // Verify final validator states
        {
            IBeefySonic.Validator memory validator0 = beefySonic.validatorByIndex(0);
            IBeefySonic.Validator memory validator1 = beefySonic.validatorByIndex(1);
            IBeefySonic.Validator memory validator2 = beefySonic.validatorByIndex(2);

            assertFalse(validator0.active, "First validator should be inactive");
            assertFalse(validator1.active, "Second validator should be inactive");
            assertTrue(validator2.active, "Third validator should remain active");
            assertTrue(validator2.delegations > 0, "Remaining funds should be delegated to third validator");
        }

        // Verify stored total is reduced by slashing losses
        uint256 finalStoredTotal = beefySonic.totalAssets();
        assertTrue(finalStoredTotal < initialStoredTotal, "Stored total should be reduced by slashing");

        // Verify exact recovery calculations
        uint256 totalRecovered = aliceRecovered + bobRecovered;
        uint256 totalFees = beefyFeeCharged + liquidityFeeCharged;
        assertApproxEqRel(
            totalRecovered + totalFees, recoveredAmount, 0.01e18, "Total recovered + fees should equal recovered amount"
        );
    }

    // Helper functions
    function _deposit(uint256 amount, string memory _name) internal returns (address user) {
        user = makeAddr(_name);
        vm.startPrank(user);
        deal(want, user, amount);
        IERC20(want).approve(address(beefySonic), amount);
        beefySonic.deposit(amount, user);
        vm.stopPrank();
    }

    function _simulateSlashing(uint256 validatorId, uint256 refundRatio) internal {
        // Simulate slashing by governance
        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        ISFC(stakingContract).deactivateValidator(validatorId, CHEATER_MASK);
        vm.stopPrank();

        assertEq(ISFC(stakingContract).isSlashed(validatorId), true);

        // Set refund ratio
        address owner = address(0x69Adb6Bd46852315ADbbfA633d2bbf792CdB3e04);
        vm.startPrank(owner);
        ISFC(stakingContract).updateSlashingRefundRatio(validatorId, refundRatio);
        vm.stopPrank();

        // Advance time and epochs
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);
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
