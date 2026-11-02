# Blueprint by Rumor

On-chain perpetual futures exchange with USDT margin and Pyth oracle pricing, deployed on BNB Smart Chain.

## Technology Stack

- Blockchain: BNB Smart Chain (BSC)
- Smart Contracts: Solidity 0.8.28, OpenZeppelin 5 (UUPS upgradeable proxy, EIP-712), Pyth pull oracle
- Frontend: Next.js, viem / wagmi (separate repository)
- Development: Foundry (forge, anvil), Envio indexer

## Supported Networks

- BNB Smart Chain Mainnet (Chain ID: 56)
- BNB Smart Chain Testnet (Chain ID: 97)
- Anvil local (Chain ID: 31337)

## Contract Addresses

All contracts are deployed only on BNB Smart Chain mainnet (Chain ID: 56).

| Contract | Address |
|----------|---------|
| PerpetualFutures (proxy) | [0xa11e95DD56cDb943a7962BdC833c38FE2D6cb8e1](https://bscscan.com/address/0xa11e95DD56cDb943a7962BdC833c38FE2D6cb8e1) |
| PerpetualFutures (implementation) | [0xd5207Bed2F3c677F68D61ceca844580eCfe5c37F](https://bscscan.com/address/0xd5207Bed2F3c677F68D61ceca844580eCfe5c37F) |
| MulticallExecutor | [0xd1b6fDeF4972ED0bf92483b2041573830EED0ad5](https://bscscan.com/address/0xd1b6fDeF4972ED0bf92483b2041573830EED0ad5) |
| USDT (collateral, BSC-USD) | [0x55d398326f99059fF775485246999027B3197955](https://bscscan.com/address/0x55d398326f99059fF775485246999027B3197955) |
| Pyth oracle | [0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594](https://bscscan.com/address/0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594) |

Per-chain addresses live in [`deployments/`](deployments/) and are written by the deploy script.

## Features

- Perpetual positions on BTC, ETH and BNB with USDT as the only collateral
- Pyth price updates bundled into every open, close and liquidation transaction
- Gasless trading: traders sign EIP-712 orders, an executor submits them (`openPosition`, `closePositionsWithSig`)
- Batch liquidations with a liquidation buffer per instrument (`liquidateBatch`)
- Pool-backed payouts: wins are paid from the pool or queued and settled by `harvest` as losses come in
- UUPS upgradeable core with owner-managed instruments, fee rates and executors

## Layout

- `src/PerpetualFutures.sol` — exchange core (positions, pricing, fees, liquidation)
- `src/Martingaler.sol` — pool accounting and the payout queue
- `src/MulticallExecutor.sol` — batches executor calls into one transaction
- `src/InstrumentLib.sol`, `src/PositionLib.sol` — instrument config and position math
- `script/Deploy.s.sol`, `script/Upgrade.s.sol`, `script/DeployMulticall.s.sol` — deployment, writes `deployments/<chainId>.json`
- `test/` — unit, fuzz and invariant tests

## Usage

```shell
npm install
forge build
forge test
```

Deploy to BSC: copy `.env.example` to `.env`, fill `RPC_URL`, `PRIVATE_KEY`, `PYTH_ADDRESS`, `USDT_ADDRESS`, then:

```shell
npm run deploy:bsc
npm run verify:bsc
```

Local stand: `anvil --chain-id 31337`, then `npm run deploy:local` deploys MockPyth and MockUSDT.

## License

[MIT](LICENSE)

---
