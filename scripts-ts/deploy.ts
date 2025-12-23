import { addAddressPadding, byteArray } from "starknet";
import {
	declareOnly,
	deployContract,
	deployer,
	executeDeployCalls,
	exportDeployments,
	loadExistingDeployments,
	registerDeployment,
	provider,
} from "./deploy-contract";
import { green, yellow, red } from "./helpers/colorize-log";
import yargs from "yargs";

/** ------------------------------
 *  ARGUMENT PARSING
 *  ------------------------------ */
const argv = yargs(process.argv.slice(2))
	.option("network", {
		type: "string",
		required: true,
	})
	.option("upgrade", {
		type: "boolean",
		description: "Upgrade Distribution + Marketplace using latest deployments",
	})
	.parseSync();

/** ------------------------------
 *   Helper: string → Cairo ByteArray
 *  ------------------------------ */
const string_to_byte_array = (str: string): string[] => {
	const ba = byteArray.byteArrayFromString(str);
	const result = [`0x${ba.data.length.toString(16)}`];

	for (const v of ba.data) result.push(v.toString());
	if (ba.pending_word) result.push(ba.pending_word.toString());

	result.push(`0x${ba.pending_word_len.toString(16)}`);
	return result;
};

/** ------------------------------
 *   Upgrade helper (1 contract)
 *  ------------------------------ */
const upgradeOne = async (contractName: string, address: string) => {
	console.log(yellow(`🔄 Upgrading ${contractName} at ${address}...`));

	// Step 1 — just declare
	const classHash = await declareOnly(contractName);

	if (!classHash) throw new Error(red("❌ Could not declare new class"));

	console.log(green(`✔ Declared new classHash: ${classHash}`));

	// Step 2 — execute upgrade(class_hash)
	const tx = await deployer.execute([
		{
			contractAddress: address,
			entrypoint: "upgrade",
			calldata: [classHash],
		},
	]);

	console.log(green(`🔄 Upgrade TX for ${contractName}: ${tx.transaction_hash}`));
	await provider.waitForTransaction(tx.transaction_hash);

	console.log(green(`✨ Successfully upgraded ${contractName}`));
	registerDeployment(contractName, {
		contract: contractName,
		address,
		classHash
	  });
	  
};

/** ------------------------------
 *   UPGRADE MODE
 *  ------------------------------ */
const upgradeMode = async () => {
	console.log(yellow("🔄 Upgrade mode activated — no redeploys"));

	const deployments = loadExistingDeployments();

	const distribution = deployments["Distribution"];
	const marketplace = deployments["Marketplace"];
	const swap = deployments["Swap"];

	if (!distribution || !marketplace) {
		console.error(
			red(
				"❌ Cannot upgrade — missing Distribution or Marketplace in deployments/<network>_latest.json"
			)
		);
		process.exit(1);
	}

	await upgradeOne("Distribution", distribution.address);
	await upgradeOne("Marketplace", marketplace.address);
	await upgradeOne("Swap", swap.address);

	exportDeployments();
	console.log(green("✔ All upgrades completed"));
};


/** ------------------------------
 *   FULL DEPLOY MODE
 *  ------------------------------ */
const deployScript = async (): Promise<void> => {
	const admin = deployer.address;

	// If --upgrade is passed → skip deploy entirely
	if (argv.upgrade) return upgradeMode();

	console.log("🚀 Deploying full system...");

	const { address: cofiCollectionAddress } = await deployContract({
		contract: "CofiCollection",
		constructorArgs: {
			default_admin: admin,
			pauser: admin,
			minter: admin,
			uri_setter: admin,
			upgrader: admin,
		},
	});

	const { address: distributionAddress } = await deployContract({
		contract: "Distribution",
		constructorArgs: { admin },
	});

	// usdc address in mainnet
	let usdcAddress = "0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb";
	if (argv.network === "sepolia") {
		const { address } = await deployContract({
			contract: "MockUSDC",
			constructorArgs: { default_admin: admin, minter: admin, upgrader: admin },
		});
		usdcAddress = address;
	}

	const { address: marketplaceAddress } = await deployContract({
		contract: "Marketplace",
		constructorArgs: {
			cofi_collection_address: cofiCollectionAddress,
			distribution_address: distributionAddress,
			usdc_address: usdcAddress,
			admin,
			market_fee: BigInt(5000),
		},
	});

	let swapAddress = "";
	if (argv.network === "mainnet") {
		const { address: swapAddressRaw } = await deployContract({
			contract: "Swap",
			constructorArgs: { admin },
		});
		swapAddress = swapAddressRaw;
	}

	console.log("CofiCollection:", green(cofiCollectionAddress));
	console.log("Distribution:", green(distributionAddress));
	console.log("Marketplace:", green(marketplaceAddress));
	console.log("Swap:", green(swapAddress));

	await executeDeployCalls();

	// Post-deploy setup
	const base_uri = process.env.TOKEN_METADATA_URL || "";
	const tx = await deployer.execute([
		{
			contractAddress: cofiCollectionAddress,
			entrypoint: "set_minter",
			calldata: { minter: marketplaceAddress },
		},
		{
			contractAddress: cofiCollectionAddress,
			entrypoint: "set_base_uri",
			calldata: string_to_byte_array(base_uri),
		},
		{
			contractAddress: distributionAddress,
			entrypoint: "set_marketplace",
			calldata: { marketplace: marketplaceAddress },
		},
	]);

	console.log("🚀 Config TX", tx.transaction_hash);
};

deployScript()
	.then(() => {
		exportDeployments();
		console.log(green("✔ All setup done"));
	})
	.catch(console.error);
