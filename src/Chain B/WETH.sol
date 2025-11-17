// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title WETH
 * @dev Minimal wrapped-ETH style ERC20 contract with deposit/withdraw and a privileged
 * bridge mint function. Uses OpenZeppelin's ERC20 and Ownable. To compile, install
 * OpenZeppelin via: `forge install OpenZeppelin/openzeppelin-contracts`.
 */
contract WETH is ERC20, Ownable {
    // Address with bridge privileges (can mint arbitrarily via `bridge`)
    address public bridgeAddress;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {
        // set initial bridge to the deployer (owner)
        bridgeAddress = msg.sender;
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Deposit ETH and receive WETH tokens
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH by burning WETH tokens
    /// @param amount Amount of WETH (in wei) to burn and withdraw
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "WETH: ETH transfer failed");
    }

    /// @notice Privileged bridge mint function. Only callable by `bridgeAddress`.
    /// @param to Recipient of minted tokens
    /// @param amount Amount to mint (in token wei)
    function bridge(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    modifier onlyBridge() {
        require(msg.sender == bridgeAddress, "WETH: caller is not bridge");
        _;
    }

    /// @notice Owner can change the bridge address
    function setBridge(address _bridge) external onlyOwner {
        bridgeAddress = _bridge;
    }
}

