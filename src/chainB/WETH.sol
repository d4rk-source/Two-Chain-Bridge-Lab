// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  WETH (Bridge Token)
 * @notice Chain B side of a two-chain bridge demo.
 *
 * A standard ERC20 token that is minted by the off-chain relayer whenever ETH is
 * locked on Chain A, and burned when that ETH is unlocked. Despite the name, this
 * token is NOT backed by ETH on Chain B — it represents ETH locked on Chain A.
 *
 * Access model:
 *  - bridgeAddress  The off-chain relayer. Can mint (bridge) and burn tokens.
 *  - owner          Deployer / admin. Can update the bridge address.
 *
 * Both bridge() and burn() are restricted to bridgeAddress so the relayer only
 * needs one role, keeping the permission model simple and symmetric.
 *
 * NOT production-ready — personal homelab project.
 */
contract WETH is ERC20, Ownable {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Address authorised to mint and burn tokens (the relayer).
    address public bridgeAddress;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the bridge address is updated.
    event BridgeUpdated(address indexed previousBridge, address indexed newBridge);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotBridge();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyBridge() {
        _checkBridge();
        _;
    }

    function _checkBridge() internal view {
        if (msg.sender != bridgeAddress) revert NotBridge();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        bridgeAddress = msg.sender;
        emit BridgeUpdated(address(0), msg.sender);
    }

    // -------------------------------------------------------------------------
    // External — bridge-only
    // -------------------------------------------------------------------------

    /// @notice Mint `amount` tokens to `to`. Called by the relayer when ETH is
    ///         locked on Chain A.
    /// @param  to     Recipient of the minted tokens.
    /// @param  amount Amount to mint (in token wei).
    function bridge(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    /// @notice Burn `amount` tokens from `from`. Called by the relayer when ETH is
    ///         unlocked on Chain A.
    /// @param  from   Address whose tokens will be burned.
    /// @param  amount Amount to burn (in token wei).
    function burn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // External — owner-only
    // -------------------------------------------------------------------------

    /// @notice Update the authorised bridge (relayer) address.
    /// @param  newBridge Address of the new bridge relayer.
    function setBridge(address newBridge) external onlyOwner {
        emit BridgeUpdated(bridgeAddress, newBridge);
        bridgeAddress = newBridge;
    }
}
