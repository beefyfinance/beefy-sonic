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
 * @title BeefySonicWithdrawalsTest
 * @dev Test suite for BeefySonic's withdrawal and pending request functionality
 *
 * This contract tests the withdrawal mechanisms in BeefySonic, including:
 * - Standard withdrawal flows
 * - Emergency withdrawal scenarios
 * - Pending request management
 * - Multiple withdrawal coordination
 * - Edge cases and security checks
 *
 * Key scenarios covered:
 * 1. Standard withdrawal lifecycle
 * 2. Multiple pending requests handling
 * 3. Emergency withdrawals under various conditions
 * 4. Withdrawal permissions and access control
 * 5. Request cancellation and modification
 * 6. Withdrawal timing and lock periods
 * 7. Partial withdrawals and claim management
 */
contract BeefySonicWithdrawalsTest is Test {
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

    function test_StandardWithdrawalFlow() public {
        // 1. Initial deposit
        address alice = _deposit(1000e18, "alice");

        // 2. Request withdrawal
        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);
        vm.stopPrank();

        // 3. Verify request details
        uint256 pendingShares = beefySonic.pendingRedeemRequest(requestId, alice);
        assertEq(pendingShares, 500e18, "Pending shares should match requested amount");

        // Initially not claimable due to lock period
        uint256 claimableShares = beefySonic.claimableRedeemRequest(requestId, alice);
        assertEq(claimableShares, 0, "Shares should not be claimable before lock period");

        // 4. Wait for lock period
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        // Verify shares are now claimable
        claimableShares = beefySonic.claimableRedeemRequest(requestId, alice);
        assertEq(claimableShares, 500e18, "Shares should be claimable after lock period");

        // 5. Complete withdrawal
        vm.startPrank(alice);
        beefySonic.withdraw(requestId, alice, alice);
        vm.stopPrank();

        // 6. Verify balances and request state
        assertEq(IERC20(want).balanceOf(alice), 500e18, "Withdrawn balance should match request");
        assertEq(beefySonic.balanceOf(alice), 500e18, "Remaining shares should be correct");
        assertEq(beefySonic.pendingRedeemRequest(requestId, alice), 0, "Request should be cleared after withdrawal");
    }

    function test_MultipleWithdrawalRequests() public {
        // 1. Setup multiple users with deposits
        address alice = _deposit(1000e18, "alice");
        address bob = _deposit(1000e18, "bob");

        // 2. Create multiple requests per user
        vm.startPrank(alice);
        uint256 request1Alice = beefySonic.requestRedeem(300e18, alice, alice);
        uint256 request2Alice = beefySonic.requestRedeem(200e18, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 request1Bob = beefySonic.requestRedeem(200e18, bob, bob);
        uint256 request2Bob = beefySonic.requestRedeem(100e18, bob, bob);
        vm.stopPrank();

        // 3. Verify all requests are tracked
        assertEq(
            beefySonic.pendingRedeemRequest(request1Alice, alice), 300e18, "Alice's first request should be tracked"
        );
        assertEq(
            beefySonic.pendingRedeemRequest(request2Alice, alice), 200e18, "Alice's second request should be tracked"
        );
        assertEq(beefySonic.pendingRedeemRequest(request1Bob, bob), 200e18, "Bob's request should be tracked");
        assertEq(beefySonic.pendingRedeemRequest(request2Bob, bob), 100e18, "Bob's second request should be tracked");

        // Initially not claimable
        assertEq(
            beefySonic.claimableRedeemRequest(request1Alice, alice),
            0,
            "Requests should not be claimable before lock period"
        );
        assertEq(beefySonic.claimableRedeemRequest(request2Alice, alice), 0);
        assertEq(beefySonic.claimableRedeemRequest(request1Bob, bob), 0);
        assertEq(beefySonic.claimableRedeemRequest(request2Bob, bob), 0);

        // 4. Process withdrawals in different orders
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        // Verify all requests are now claimable
        assertEq(
            beefySonic.claimableRedeemRequest(request1Alice, alice),
            300e18,
            "Requests should be claimable after lock period"
        );
        assertEq(beefySonic.claimableRedeemRequest(request2Alice, alice), 200e18);
        assertEq(beefySonic.claimableRedeemRequest(request1Bob, bob), 200e18);
        assertEq(beefySonic.claimableRedeemRequest(request2Bob, bob), 100e18);

        vm.startPrank(alice);
        beefySonic.withdraw(request2Alice, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        beefySonic.withdraw(request1Bob, bob, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        beefySonic.withdraw(request1Alice, alice, alice);
        vm.stopPrank();

        // 5. Verify final balances and request states
        assertEq(beefySonic.balanceOf(alice), 500e18, "Alice's final share balance should be correct");
        assertEq(beefySonic.balanceOf(bob), 700e18, "Bob's final share balance should be correct");

        // Verify all requests are cleared
        assertEq(beefySonic.pendingRedeemRequest(request1Alice, alice), 0, "Processed requests should be cleared");
        assertEq(beefySonic.pendingRedeemRequest(request2Alice, alice), 0);
        assertEq(beefySonic.pendingRedeemRequest(request1Bob, bob), 0);
    }

    function test_EmergencyWithdrawalScenarios() public {
        // 1. Setup initial state
        address alice = _deposit(1000e18, "alice");

        // 2. Create withdrawal request
        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);
        vm.stopPrank();

        // Verify initial request state
        assertEq(beefySonic.pendingRedeemRequest(requestId, alice), 500e18, "Initial request should be tracked");
        assertEq(beefySonic.claimableRedeemRequest(requestId, alice), 0, "Request should not be claimable initially");

        // 3. Simulate validator slashing
        _simulateSlashing(beefyValidatorId, 0.7e18);

        // 4. Try emergency withdrawal
        vm.startPrank(alice);
        uint256 beforeBalance = IERC20(want).balanceOf(alice);
        beefySonic.emergencyWithdraw(requestId, alice, alice);
        uint256 afterBalance = IERC20(want).balanceOf(alice);

        // Should receive ~70% of requested amount
        assertApproxEqRel(
            afterBalance - beforeBalance,
            (500e18 * 0.7e18) / 1e18,
            0.01e18,
            "Emergency withdrawal amount should be proportional to refund ratio"
        );
        vm.stopPrank();

        // 5. Verify request is cleared
        assertEq(
            beefySonic.pendingRedeemRequest(requestId, alice), 0, "Request should be cleared after emergency withdrawal"
        );
        assertEq(
            beefySonic.claimableRedeemRequest(requestId, alice),
            0,
            "Request should not be claimable after emergency withdrawal"
        );
    }

    function test_WithdrawalPermissions() public {
        // 1. Setup withdrawal request
        address alice = _deposit(1000e18, "alice");
        address bob = makeAddr("bob");

        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, bob, alice);
        vm.stopPrank();

        // Verify initial request state
        assertEq(beefySonic.pendingRedeemRequest(requestId, bob), 500e18, "Request should be tracked under new owner");

        // 2. Test unauthorized withdrawal
        address charlie = makeAddr("charlie");
        vm.startPrank(charlie);
        vm.expectRevert();
        beefySonic.withdraw(requestId, alice, bob);
        vm.stopPrank();

        // 3. Test withdrawal with correct permissions
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        assertEq(beefySonic.claimableRedeemRequest(requestId, bob), 500e18, "Request should be claimable by owner");

        vm.startPrank(bob);
        beefySonic.withdraw(requestId, bob, bob);
        vm.stopPrank();

        // 4. Verify final state
        assertEq(IERC20(want).balanceOf(bob), 500e18, "Receiver should get the withdrawn amount");
        assertEq(beefySonic.pendingRedeemRequest(requestId, bob), 0, "Request should be cleared after withdrawal");
    }

    function test_WithdrawalTimingAndLocks() public {
        // 1. Setup withdrawal request
        address alice = _deposit(1000e18, "alice");

        vm.startPrank(alice);
        uint256 requestId = beefySonic.requestRedeem(500e18, alice, alice);

        // Verify initial state
        assertEq(beefySonic.pendingRedeemRequest(requestId, alice), 500e18, "Request should be tracked");
        assertEq(beefySonic.claimableRedeemRequest(requestId, alice), 0, "Request should not be claimable initially");

        // 2. Try to withdraw before lock period
        vm.expectRevert();
        beefySonic.withdraw(requestId, alice, alice);

        // 3. Try just before exact lock duration
        _advanceEpoch(4);
        vm.warp(block.timestamp + beefySonic.withdrawDuration() - 1);
        assertEq(
            beefySonic.claimableRedeemRequest(requestId, alice),
            0,
            "Request should not be claimable at exact withdrawal duration"
        );
        vm.expectRevert();
        beefySonic.withdraw(requestId, alice, alice);

        // 4. Success after lock period
        vm.warp(block.timestamp + 1);
        assertEq(
            beefySonic.claimableRedeemRequest(requestId, alice), 500e18, "Request should be claimable after lock period"
        );
        vm.startPrank(alice);
        beefySonic.withdraw(requestId, alice, alice);
        vm.stopPrank();

        // Verify final state
        assertEq(IERC20(want).balanceOf(alice), 500e18, "Withdrawn amount should be correct");
        assertEq(beefySonic.pendingRedeemRequest(requestId, alice), 0, "Request should be cleared after withdrawal");
    }

    function test_PartialWithdrawals() public {
        // 1. Setup large deposit
        address alice = _deposit(1000e18, "alice");

        // 2. Create multiple partial withdrawal requests
        vm.startPrank(alice);
        uint256 request1 = beefySonic.requestRedeem(100e18, alice, alice);
        uint256 request2 = beefySonic.requestRedeem(200e18, alice, alice);
        uint256 request3 = beefySonic.requestRedeem(300e18, alice, alice);

        // Verify initial request states
        assertEq(beefySonic.pendingRedeemRequest(request1, alice), 100e18, "First request should be tracked");
        assertEq(beefySonic.pendingRedeemRequest(request2, alice), 200e18, "Second request should be tracked");
        assertEq(beefySonic.pendingRedeemRequest(request3, alice), 300e18, "Third request should be tracked");

        // 3. Process requests in order
        vm.warp(block.timestamp + 14 days + 1);
        _advanceEpoch(4);

        assertEq(beefySonic.claimableRedeemRequest(request1, alice), 100e18, "First request should be claimable");
        assertEq(beefySonic.claimableRedeemRequest(request2, alice), 200e18, "Second request should be claimable");
        assertEq(beefySonic.claimableRedeemRequest(request3, alice), 300e18, "Third request should be claimable");

        vm.startPrank(alice);
        beefySonic.withdraw(request1, alice, alice);
        beefySonic.withdraw(request2, alice, alice);
        beefySonic.withdraw(request3, alice, alice);
        vm.stopPrank();

        // 4. Verify final state
        assertEq(IERC20(want).balanceOf(alice), 600e18, "Total withdrawn amount should be correct");
        assertEq(beefySonic.balanceOf(alice), 400e18, "Remaining shares should be correct");
        assertEq(beefySonic.pendingRedeemRequest(request1, alice), 0, "All requests should be cleared");
        assertEq(beefySonic.pendingRedeemRequest(request2, alice), 0);
        assertEq(beefySonic.pendingRedeemRequest(request3, alice), 0);
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

    function _simulateSlashing(uint256 validatorId, uint256 refundRatio) internal {
        // Simulate slashing by governance
        vm.startPrank(address(0xD100ae0000000000000000000000000000000000));
        ISFC(stakingContract).deactivateValidator(validatorId, 1 << 7);
        vm.stopPrank();

        // Set refund ratio
        address owner = address(0x69Adb6Bd46852315ADbbfA633d2bbf792CdB3e04);
        vm.startPrank(owner);
        ISFC(stakingContract).updateSlashingRefundRatio(validatorId, refundRatio);
        vm.stopPrank();

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
