// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LockAndSwap
 * @notice Accepts ETH, locks it in the contract, and emits an event indicating how
 * much ETH was used to "swap". Includes an owner-only withdrawal function to
 * recover locked funds.
 */
contract LockAndSwap {
    // Total locked ETH tracked in contract (for convenience)
    uint256 public totalLocked;

    // Track how much ETH each address has deposited
    mapping(address => uint256) public deposits;

    // Owner who can withdraw locked funds
    address public owner;

    // Emitted when ETH is locked for a swap
    event SwapLocked(address indexed sender, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "LockAndSwap: caller is not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Lock ETH in the contract and emit the swap event
    /// @dev Caller should send ETH with the call
    function lockAndSwap() external payable {
        require(msg.value > 0, "LockAndSwap: zero value");
        totalLocked += msg.value;
        deposits[msg.sender] += msg.value;
        emit SwapLocked(msg.sender, msg.value);
    }

    /// @notice Convenience payable fallback to accept ETH and treat as swap
    receive() external payable {
        totalLocked += msg.value;
        deposits[msg.sender] += msg.value;
        emit SwapLocked(msg.sender, msg.value);
    }

    /// @notice Owner can withdraw ETH from the contract
    /// @param to Recipient address
    /// @param amount Amount in wei to withdraw
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "LockAndSwap: insufficient balance");
        totalLocked -= amount;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "LockAndSwap: transfer failed");
    }

    /// @notice Returns how much ETH an account has deposited
    function depositOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    /// @notice Change owner
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "LockAndSwap: zero address");
        owner = newOwner;
    }
}
