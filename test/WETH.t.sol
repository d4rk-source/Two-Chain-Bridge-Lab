// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/chainB/WETH.sol";

contract WETHTest is Test {
    WETH weth;

    address relayer = makeAddr("relayer");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");

    function setUp() public {
        weth = new WETH("Wrapped Ether", "WETH");
        // Transfer bridge role to the relayer (mirrors the production setup)
        weth.setBridge(relayer);
    }

    // -------------------------------------------------------------------------
    // bridge (mint)
    // -------------------------------------------------------------------------

    function test_bridge_mintsToRecipient() public {
        vm.prank(relayer);
        weth.bridge(alice, 1 ether);

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.totalSupply(), 1 ether);
    }

    function test_bridge_accumulatesMultipleMints() public {
        vm.prank(relayer);
        weth.bridge(alice, 1 ether);
        vm.prank(relayer);
        weth.bridge(alice, 0.5 ether);

        assertEq(weth.balanceOf(alice), 1.5 ether);
    }

    function test_bridge_revertsForNonBridge() public {
        vm.expectRevert(WETH.NotBridge.selector);
        vm.prank(alice);
        weth.bridge(alice, 1 ether);
    }

    function test_bridge_revertsForOwnerWhenNotBridge() public {
        // Owner does not automatically have bridge privileges after setBridge.
        vm.expectRevert(WETH.NotBridge.selector);
        weth.bridge(alice, 1 ether); // address(this) is owner, not relayer
    }

    // -------------------------------------------------------------------------
    // burn
    // -------------------------------------------------------------------------

    function test_burn_destroysTokens() public {
        vm.prank(relayer);
        weth.bridge(alice, 2 ether);
        vm.prank(relayer);
        weth.burn(alice, 1 ether);

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.totalSupply(), 1 ether);
    }

    function test_burn_revertsForNonBridge() public {
        vm.prank(relayer);
        weth.bridge(alice, 1 ether);

        vm.expectRevert(WETH.NotBridge.selector);
        vm.prank(alice);
        weth.burn(alice, 1 ether);
    }

    function test_burn_revertsForOwnerWhenNotBridge() public {
        vm.prank(relayer);
        weth.bridge(alice, 1 ether);

        vm.expectRevert(WETH.NotBridge.selector);
        weth.burn(alice, 1 ether); // address(this) is owner, not relayer
    }

    // -------------------------------------------------------------------------
    // setBridge
    // -------------------------------------------------------------------------

    function test_setBridge_updatesBridgeAddress() public {
        address newRelayer = makeAddr("newRelayer");
        weth.setBridge(newRelayer);
        assertEq(weth.bridgeAddress(), newRelayer);
    }

    function test_setBridge_emitsBridgeUpdated() public {
        address newRelayer = makeAddr("newRelayer");
        vm.expectEmit(true, true, false, false);
        emit WETH.BridgeUpdated(relayer, newRelayer);
        weth.setBridge(newRelayer);
    }

    function test_setBridge_oldBridgeCanNoLongerMint() public {
        weth.setBridge(makeAddr("newRelayer"));

        vm.expectRevert(WETH.NotBridge.selector);
        vm.prank(relayer); // old relayer
        weth.bridge(alice, 1 ether);
    }

    function test_setBridge_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        weth.setBridge(alice);
    }

    // -------------------------------------------------------------------------
    // ERC20 standard behaviour
    // -------------------------------------------------------------------------

    function test_erc20_transfer() public {
        vm.prank(relayer);
        weth.bridge(alice, 5 ether);

        vm.prank(alice);
        bool ok = weth.transfer(bob, 2 ether);
        assertTrue(ok);

        assertEq(weth.balanceOf(alice), 3 ether);
        assertEq(weth.balanceOf(bob),   2 ether);
    }

    function test_erc20_approve_and_transferFrom() public {
        vm.prank(relayer);
        weth.bridge(alice, 5 ether);

        vm.prank(alice);
        weth.approve(bob, 2 ether);

        vm.prank(bob);
        bool ok = weth.transferFrom(alice, bob, 2 ether);
        assertTrue(ok);

        assertEq(weth.balanceOf(alice), 3 ether);
        assertEq(weth.balanceOf(bob),   2 ether);
    }

    function test_erc20_metadata() public view {
        assertEq(weth.name(),     "Wrapped Ether");
        assertEq(weth.symbol(),   "WETH");
        assertEq(weth.decimals(), 18);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_bridge_tracksSupply(uint128 amount) public {
        vm.assume(amount > 0);
        vm.prank(relayer);
        weth.bridge(alice, amount);

        assertEq(weth.totalSupply(),    amount);
        assertEq(weth.balanceOf(alice), amount);
    }

    function testFuzz_burn_reducesSupply(uint128 mint, uint128 burn_) public {
        vm.assume(mint > 0 && burn_ <= mint);
        vm.prank(relayer);
        weth.bridge(alice, mint);
        vm.prank(relayer);
        weth.burn(alice, burn_);

        assertEq(weth.totalSupply(),    mint - burn_);
        assertEq(weth.balanceOf(alice), mint - burn_);
    }
}
