#!/usr/bin/env node
import { execSync } from "node:child_process";
import yargs from "yargs";
import { smartCompile } from "../compile";

interface CommandLineOptions {
	_: string[]; // Non-hyphenated arguments are usually under the `_` key
	$0: string; // The script name or path is under the `$0` key
	network?: string; // The --network option
	reset?: boolean;
	upgrade?: boolean;
	feature?: string;
}

function main() {
	const argv = yargs(process.argv.slice(2))
		.option("network", {
			type: "string",
			choices: ["devnet", "sepolia", "mainnet"],
			default: "devnet",
			description: "Specify the network to deploy to",
		})
		.option("reset", {
			type: "boolean",
			description:
				"Reset deployments (overwrites the latest file only, previous generated files will remain)",
			default: true,
			hidden: true,
		})
		.option("no-reset", {
			type: "boolean",
			description: "Do not reset deployments (keep existing deployments)",
			default: false,
		})
		.option("upgrade", {
			type: "boolean",
			description: "Upgrade contracts (Distribution + Marketplace)",
			default: false,
		})
		.option("feature", {
			type: "string",
			description: "Feature to deploy",
			default: "",
		})
		.demandOption(["network"])
		.strict() // This will make yargs throw an error for unknown options
		.help()
		.parseSync() as CommandLineOptions;

	if (argv._.length > 0) {
		console.error(
			"❌ Invalid arguments, only --network or --no-reset can be passed in",
		);
		return;
	}

	const resetFlag = argv.reset === false ? "--no-reset" : "";

	try {
		smartCompile({ force: argv.feature?.length > 0 ? true : false }, argv.feature || "");

		const command = `ts-node scripts-ts/deploy.ts --network ${argv.network || "devnet"}${resetFlag ? ` ${resetFlag}` : ""}${argv.upgrade ? ` --upgrade` : ""} && ts-node scripts-ts/helpers/parse-deployments.ts`;

		execSync(command, { stdio: "inherit" });
	} catch (error) {
		console.error("Error during deployment:", error);
		process.exit(1);
	}
}

if (require.main === module) {
	main();
}
