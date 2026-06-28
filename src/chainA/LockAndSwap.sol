// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  LockAndSwap
 * @notice Chain A side of a two-chain bridge demo.
 *
 * Users deposit ETH here to initiate a cross-chain "swap." An off-chain relayer
 * watches for SwapLocked events and mints an equivalent wrapped token on Chain B.
 * Withdrawing here emits a Withdraw event that tells the relayer to burn the
 * corresponding Chain B tokens.
 *
 * Design notes:
 *  - Follows the Checks-Effects-Interactions pattern on all state-changing paths.
 *  - ReentrancyGuard is added as belt-and-suspenders on withdrawal functions.
 *  - Custom errors are used in place of revert strings for lower gas cost.
 *  - emergencyWithdraw does not update per-user deposit records; it is intended
 *    solely for stuck-fund recovery and should be paired with manual Chain B
 *    accounting if ever invoked.
 *
 * NOT production-ready — personal homelab project.
 */
contract LockAndSwap is ReentrancyGuard {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Sum of all ETH currently locked in the contract.
    uint256 public totalLocked;

    /// @notice ETH balance attributed to each depositor.
    mapping(address => uint256) public deposits;

    /// @notice Address with owner-level privileges.
    address public owner;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a user locks ETH to initiate a swap.
    event SwapLocked(address indexed sender, uint256 amount);

    /// @notice Emitted when a user withdraws their own ETH.
    event Withdraw(address indexed account, uint256 amount);

    /// @notice Emitted when contract ownership changes.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroValue();
    error ZeroAmount();
    error InsufficientDeposit();
    error InsufficientContractBalance();
    error TransferFailed();
    error NotOwner();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // -------------------------------------------------------------------------
    // External — user-facing
    // -------------------------------------------------------------------------

    /// @notice Lock ETH in the contract and initiate a cross-chain swap.
    function lockAndSwap() external payable {
        if (msg.value == 0) revert ZeroValue();
        _lock(msg.sender, msg.value);
    }

    /// @notice Accept ETH sent directly to the contract (treated identically to lockAndSwap).
    receive() external payable {
        if (msg.value == 0) revert ZeroValue();
        _lock(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH previously deposited by the caller.
    /// @dev    Emits Withdraw so the relayer can burn the corresponding Chain B tokens.
    /// @param  amount Amount in wei to withdraw.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (deposits[msg.sender] < amount) revert InsufficientDeposit();
        if (address(this).balance < amount) revert InsufficientContractBalance();

        deposits[msg.sender] -= amount;
        totalLocked -= amount;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // External — owner-only
    // -------------------------------------------------------------------------

    /// @notice Emergency fund recovery. Sends ETH to any address without updating
    ///         per-user deposit records. Use only as a last resort; Chain B token
    ///         balances must be reconciled manually if this is ever called.
    /// @param  to     Recipient address.
    /// @param  amount Amount in wei to send.
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (address(this).balance < amount) revert InsufficientContractBalance();
        totalLocked -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdraw(to, amount);
    }

    /// @notice Transfer contract ownership.
    /// @param  newOwner Address of the new owner.
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    /// @notice Returns the ETH amount deposited by `account`.
    function depositOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Shared logic for lockAndSwap() and receive().
    function _lock(address sender, uint256 amount) internal {
        totalLocked += amount;
        deposits[sender] += amount;
        emit SwapLocked(sender, amount);
    }
}
