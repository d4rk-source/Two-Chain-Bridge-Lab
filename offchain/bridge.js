#!/usr/bin/env node
"use strict";
// Read contract name and address from a Forge broadcast JSON and call its `reach()` function.
// Usage:
//   npm install ethers
//   DEPLOY_JSON=broadcast/DeployCongrats.s.sol/31337/run-1763265358157.json \
//   RPC_URL=http://127.0.0.1:8545 \
//   PRIVATE_KEY=0x... \
//   node offchain/bridge.js

const fs = require("fs");
const path = require("path");
// Support both ethers v5 and v6 import styles when using CommonJS `require`
let ethers = require("ethers");
if (ethers.ethers) ethers = ethers.ethers;

const DEFAULT_JSON = "broadcast/DeployCongrats.s.sol/31337/run-1763265358157.json";

function normalizeAddress(addr) {
	if (!addr) return addr;
	try {
		if (ethers && ethers.utils && typeof ethers.utils.getAddress === "function") {
			return ethers.utils.getAddress(addr);
		}
		if (ethers && typeof ethers.getAddress === "function") {
			return ethers.getAddress(addr);
		}
	} catch (e) {
		// fallthrough
	}
	// last resort: return lowercased prefixed address
	return addr;
}

function loadDeployInfo(filePath) {
	const j = JSON.parse(fs.readFileSync(filePath, "utf8"));
	const txs = j.transactions || [];
	if (txs.length > 0) {
		const t0 = txs[0];
		const addr = t0.contractAddress;
		const name = t0.contractName;
		if (addr) return { name, address: normalizeAddress(addr) };
	}
	const returnsField = j.returns || {};
	if (returnsField["0"] && returnsField["0"].value) {
		return { name: null, address: normalizeAddress(returnsField["0"].value) };
	}
	throw new Error("No contract address found in deploy JSON");
}

const ABI = [
	"function reach()",
	"event Reached(string message)",
];

async function main() {
	const deployJson = process.env.DEPLOY_JSON || DEFAULT_JSON;
	const resolved = path.resolve(deployJson);
	if (!fs.existsSync(resolved)) {
		console.error(`Deploy JSON not found: ${resolved}`);
		process.exit(2);
	}

	const info = loadDeployInfo(resolved);
	console.log(`Loaded contract ${info.name || "<unknown>"} at ${info.address}`);

	const rpc = process.env.RPC_URL || "http://127.0.0.1:8545";
	let provider;
	if (ethers && ethers.providers && ethers.providers.JsonRpcProvider) {
		provider = new ethers.providers.JsonRpcProvider(rpc);
	} else if (ethers && typeof ethers.JsonRpcProvider === "function") {
		provider = new ethers.JsonRpcProvider(rpc);
	} else if (ethers && typeof ethers.getDefaultProvider === "function") {
		provider = ethers.getDefaultProvider(rpc);
	} else {
		console.error("Unsupported ethers version: cannot construct JsonRpcProvider");
		process.exit(1);
	}
	try {
		await provider.getBlockNumber();
	} catch (err) {
		console.error("Failed to connect to RPC:", rpc, err.message);
		process.exit(3);
	}
	const chainId = (await provider.getNetwork()).chainId;
	console.log("Connected to", rpc, "chainId=", chainId);

	// choose signer (wallet from PRIVATE_KEY or unlocked node signer)
	let signer;
	let signerAddress;
	if (process.env.PRIVATE_KEY) {
		signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
		signerAddress = signer.address;
		console.log("Using wallet:", signerAddress);
	} else {
		// try unlocked first account
		try {
			signer = provider.getSigner(0);
			signerAddress = await signer.getAddress();
			console.log("Using unlocked account:", signerAddress);
		} catch (err) {
			console.error("No PRIVATE_KEY provided and no unlocked accounts available on the node. Set PRIVATE_KEY env var.");
			process.exit(4);
		}
	}

	const code = await provider.getCode(info.address);
	console.log("Contract code length:", code.length, "bytes");
	let contract;
	if (!code || code === "0x" || code === "0x0") {
		console.log("No contract code at address", info.address, "- deploying a new Congrats contract using compiled artifact");
		const artifactPath = path.resolve("out/Congrats.sol/Congrats.json");
		if (!fs.existsSync(artifactPath)) {
			console.error("Compiled artifact not found at", artifactPath);
			process.exit(1);
		}
		const art = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
		const factory = new ethers.ContractFactory(art.abi, art.bytecode.object || art.bytecode, signer);
		const deployed = await factory.deploy();
		// cross-version compatibility: wait for deployment using whichever API is available
		if (typeof deployed.wait === "function") {
			await deployed.wait();
		} else if (typeof deployed.waitForDeployment === "function") {
			await deployed.waitForDeployment();
		} else if (deployed.deployTransaction && typeof deployed.deployTransaction.wait === "function") {
			await deployed.deployTransaction.wait();
		} else if (typeof deployed.deployed === "function") {
			await deployed.deployed();
		}
		// determine deployed address across ethers versions
		let deployedAddress = deployed.address || deployed.target || null;
		if (!deployedAddress && deployed.deployTransaction && deployed.deployTransaction.hash) {
			const r = await provider.getTransactionReceipt(deployed.deployTransaction.hash);
			deployedAddress = r && r.contractAddress;
		}
		console.log("Deployed Congrats at", deployedAddress);
		if (!deployedAddress) {
			console.error("Failed to determine deployed contract address");
			process.exit(1);
		}
		contract = new ethers.Contract(deployedAddress, ABI, provider);
	} else {
		contract = new ethers.Contract(info.address, ABI, provider);
	}

	const contractWithSigner = contract.connect(signer);
	console.log("Sending transaction to call reach()...");
	const nonce = await provider.getTransactionCount(signerAddress);
	const tx = await contractWithSigner.reach({ gasLimit: 200000, nonce });
	console.log("Sent tx:", tx.hash);
	const receipt = await tx.wait();
	console.log("Receipt status:", receipt.status);

	// Try to decode Reached events
	const iface = contract.interface;
	let found = false;
	for (const log of receipt.logs) {
		try {
			const parsed = iface.parseLog(log);
			if (parsed && parsed.name === "Reached") {
				console.log("Event Reached:", parsed.args.message);
				found = true;
			}
		} catch (e) {
			// not our event, ignore
		}
	}
	if (!found) {
		console.log("No Reached events found in receipt");
		console.log("Receipt logs:", JSON.stringify(receipt.logs, null, 2));
	}
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});