# CofiBlocks Contracts

## Deployment Guide

Follow these steps to deploy the CofiBlocks contracts on the StarkNet network.

### 1. Configure the `.env` file

Set the following environment variables in your `.env` file with the details of a prefunded wallet. This wallet will act as the admin address:

- **`PRIVATE_KEY_MAINNET`** – The private key of the admin wallet.
- **`ACCOUNT_ADDRESS_MAINNET`** – The address of the admin wallet.
- **`TOKEN_METADATA_URL`** – The IPFS URL to serve as the token metadata.
- **`RPC_URL_MAINNET`** – The rpc url to use to connect to the starknet network.
  
  The Token Metadata URL should follow the format: `ipfs://<CID>/{id}.json`, where `{id}` will be dynamically replaced with the actual token ID by clients when fetching metadata.
  
  **Example:**
  ```
  ipfs://bafybeihevtihdmcjkdh6sjdtkbdjnngbfdlr3tjk2dfmvd3demdm57o3va/{id}.json
  ```
  For token ID `1`, the resulting URL will be:
  ```
  ipfs://bafybeihevtihdmcjkdh6sjdtkbdjnngbfdlr3tjk2dfmvd3demdm57o3va/1.json
  ```

### 2. Install dependencies

Run the following command to install project dependencies:
```bash
bun i
```

### 3. Deploy the contracts

To deploy the contracts on mainnet, run:
```bash
bun deploy
```

This command will:
- Deploy contracts **CofiCollections**, **Marketplace** and **Distribution**.
- Set the **Marketplace** contract as the minter in the **CofiCollection** contract.
- Set the distribution contract on Marketplace.
- Set the `base_uri` in the **CofiCollection** contract using the `TOKEN_METADATA_URL` value from the `.env` file.

### 4. Retrieve deployed contract addresses

Once the deployment is complete, the contract addresses will be available in:
- The terminal output.
- The file located at: `deployments/deployedContracts.ts`.


## Testing
To test the contracts, follow these steps.

1. Go to contracts folder
```bash
cd contracts
```

2. Run test command
```bash
scarb test
```
