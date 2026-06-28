// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/chainA/LockAndSwap.sol";

contract LockAndSwapTest is Test {
    LockAndSwap las;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        las = new LockAndSwap();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
    }

    // -------------------------------------------------------------------------
    // lockAndSwap
    // -------------------------------------------------------------------------

    function test_lockAndSwap_updatesState() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();

        assertEq(las.totalLocked(), 1 ether);
        assertEq(las.deposits(alice), 1 ether);
        assertEq(address(las).balance, 1 ether);
    }

    function test_lockAndSwap_emitsSwapLocked() public {
        vm.expectEmit(true, false, false, true);
        emit LockAndSwap.SwapLocked(alice, 1 ether);

        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();
    }

    function test_lockAndSwap_accumulatesMultipleDeposits() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();
        vm.prank(alice);
        las.lockAndSwap{value: 0.5 ether}();

        assertEq(las.deposits(alice), 1.5 ether);
        assertEq(las.totalLocked(), 1.5 ether);
    }

    function test_lockAndSwap_tracksMultipleDepositors() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();
        vm.prank(bob);
        las.lockAndSwap{value: 2 ether}();

        assertEq(las.deposits(alice), 1 ether);
        assertEq(las.deposits(bob),   2 ether);
        assertEq(las.totalLocked(),   3 ether);
    }

    function test_lockAndSwap_revertsOnZeroValue() public {
        vm.expectRevert(LockAndSwap.ZeroValue.selector);
        vm.prank(alice);
        las.lockAndSwap{value: 0}();
    }

    // -------------------------------------------------------------------------
    // receive
    // -------------------------------------------------------------------------

    function test_receive_treatsDirectTransferAsSwap() public {
        vm.prank(alice);
        (bool ok,) = address(las).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(las.deposits(alice), 1 ether);
        assertEq(las.totalLocked(), 1 ether);
    }

    function test_receive_emitsSwapLocked() public {
        vm.expectEmit(true, false, false, true);
        emit LockAndSwap.SwapLocked(alice, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(las).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // -------------------------------------------------------------------------
    // withdraw(uint256)
    // -------------------------------------------------------------------------

    function test_withdraw_sendsFundsToSender() public {
        vm.prank(alice);
        las.lockAndSwap{value: 2 ether}();

        uint256 before = alice.balance;
        vm.prank(alice);
        las.withdraw(1 ether);

        assertEq(alice.balance, before + 1 ether);
    }

    function test_withdraw_updatesState() public {
        vm.prank(alice);
        las.lockAndSwap{value: 2 ether}();
        vm.prank(alice);
        las.withdraw(1 ether);

        assertEq(las.deposits(alice), 1 ether);
        assertEq(las.totalLocked(), 1 ether);
        assertEq(address(las).balance, 1 ether);
    }

    function test_withdraw_emitsWithdraw() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();

        vm.expectEmit(true, false, false, true);
        emit LockAndSwap.Withdraw(alice, 1 ether);

        vm.prank(alice);
        las.withdraw(1 ether);
    }

    function test_withdraw_fullAmountLeavesZeroBalance() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();
        vm.prank(alice);
        las.withdraw(1 ether);

        assertEq(las.deposits(alice), 0);
        assertEq(las.totalLocked(), 0);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.expectRevert(LockAndSwap.ZeroAmount.selector);
        vm.prank(alice);
        las.withdraw(0);
    }

    function test_withdraw_revertsWhenExceedingDeposit() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();

        vm.expectRevert(LockAndSwap.InsufficientDeposit.selector);
        vm.prank(alice);
        las.withdraw(2 ether);
    }

    function test_withdraw_revertsForNonDepositor() public {
        vm.expectRevert(LockAndSwap.InsufficientDeposit.selector);
        vm.prank(alice);
        las.withdraw(1 ether);
    }

    function test_withdraw_depositsAreIndependent() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();
        vm.prank(bob);
        las.lockAndSwap{value: 2 ether}();

        // Bob withdraws; Alice's deposit must be unaffected
        vm.prank(bob);
        las.withdraw(2 ether);

        assertEq(las.deposits(alice), 1 ether);
        assertEq(las.deposits(bob),   0);
        assertEq(las.totalLocked(),   1 ether);
    }

    // -------------------------------------------------------------------------
    // emergencyWithdraw
    // -------------------------------------------------------------------------

    function test_emergencyWithdraw_sendsToRecipient() public {
        vm.prank(alice);
        las.lockAndSwap{value: 3 ether}();

        address payable treasury = payable(makeAddr("treasury"));
        uint256 before = treasury.balance;

        las.emergencyWithdraw(treasury, 1 ether);

        assertEq(treasury.balance, before + 1 ether);
        assertEq(las.totalLocked(), 2 ether);
    }

    function test_emergencyWithdraw_revertsForNonOwner() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1 ether}();

        vm.expectRevert(LockAndSwap.NotOwner.selector);
        vm.prank(alice);
        las.emergencyWithdraw(payable(alice), 1 ether);
    }

    function test_emergencyWithdraw_revertsOnInsufficientBalance() public {
        vm.expectRevert(LockAndSwap.InsufficientContractBalance.selector);
        las.emergencyWithdraw(payable(alice), 1 ether);
    }

    // -------------------------------------------------------------------------
    // setOwner
    // -------------------------------------------------------------------------

    function test_setOwner_updatesOwner() public {
        las.setOwner(alice);
        assertEq(las.owner(), alice);
    }

    function test_setOwner_emitsOwnershipTransferred() public {
        vm.expectEmit(true, true, false, false);
        emit LockAndSwap.OwnershipTransferred(address(this), alice);
        las.setOwner(alice);
    }

    function test_setOwner_newOwnerCanExercisePrivileges() public {
        las.setOwner(alice);
        vm.prank(bob);
        las.lockAndSwap{value: 1 ether}();

        vm.prank(alice);
        las.emergencyWithdraw(payable(alice), 1 ether);

        assertEq(alice.balance, 11 ether); // 10 initial + 1 withdrawn
    }

    function test_setOwner_revertsOnZeroAddress() public {
        vm.expectRevert(LockAndSwap.ZeroAddress.selector);
        las.setOwner(address(0));
    }

    function test_setOwner_revertsForNonOwner() public {
        vm.expectRevert(LockAndSwap.NotOwner.selector);
        vm.prank(alice);
        las.setOwner(alice);
    }

    // -------------------------------------------------------------------------
    // depositOf
    // -------------------------------------------------------------------------

    function test_depositOf_matchesDepositsMapping() public {
        vm.prank(alice);
        las.lockAndSwap{value: 1.5 ether}();
        assertEq(las.depositOf(alice), las.deposits(alice));
    }

    function test_depositOf_returnsZeroForUnknownAddress() public {
        assertEq(las.depositOf(makeAddr("nobody")), 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_lockAndSwap_tracksDeposit(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(alice, amount);
        vm.prank(alice);
        las.lockAndSwap{value: amount}();

        assertEq(las.depositOf(alice), amount);
        assertEq(las.totalLocked(), amount);
    }

    function testFuzz_withdraw_partialAmount(uint96 deposit, uint96 withdrawal) public {
        vm.assume(deposit > 0);
        vm.assume(withdrawal > 0 && withdrawal <= deposit);

        vm.deal(alice, deposit);
        vm.prank(alice);
        las.lockAndSwap{value: deposit}();

        vm.prank(alice);
        las.withdraw(withdrawal);

        assertEq(las.depositOf(alice), deposit - withdrawal);
        assertEq(las.totalLocked(),    deposit - withdrawal);
    }
}
