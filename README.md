# MATURRA Protocol

**The first liquid market for locked capital.**

Maturra tokenizes the real, inflation-adjusted value of locked capital. Deposit USDC, lock it for a chosen duration, and receive a **TimeNFT** — a liquid, tradeable position representing your capital and its real return. Need to exit early? Sell your position on the marketplace. A buyer acquires future value at a discount; you get instant liquidity.

> Lock for years. Exit tomorrow.

---

## How it works

1. **Deposit** USDC into the vault and choose a lock duration (7 days to 4 years).
2. **Oracle** computes real inflation by blending Truflation (70%) and Pyth CPI (30%).
3. **Mint** a TimeNFT representing your position, with on-chain metadata.
4. **Trade or redeem** — sell the position on the marketplace, or redeem at maturity.

A 0.5% redemption fee and 1% NFT royalty both route to an automatic buyback-and-burn of the $MATURRA token.

---

## Architecture

| Contract | Role |
|----------|------|
| `MaturraVault.sol` | Core ERC-4626 vault — deposits, locks, NFT minting, redemption |
| `MaturraOracle.sol` | Dual-source inflation oracle (Truflation + Pyth CPI) with circuit breaker |
| `TimeNFT.sol` | ERC-721 position token with on-chain SVG metadata |
| `MaturraToken.sol` | $MATURRA — fixed 1B supply, deflationary, no mint function |
| `BurnRouter.sol` | Automatic buyback-and-burn engine |
| `MaturraMarket.sol` | Peer-to-peer marketplace for TimeNFT positions |

Built with Foundry + OpenZeppelin v5. **36/36 tests passing.**

---

## Deployment — Base Sepolia (testnet)

Live and verifiable on Base Sepolia:

| Contract | Address |
|----------|---------|
| MaturraVault | `0x484E79aF968f9cB6f338cb60435c2826f76BCCE3` |
| TimeNFT | `0x99f6FB3B294B96A05BCf8a20F9e7E5E2e572256B` |
| MaturraOracle | `0x72Ffa6F4055ADDDb7B219F64a33C6E440Cc45C52` |
| MaturraToken | `0x3534dd0c6C14dF1dE2d20942E84a16A0205C3f2C` |
| BurnRouter | `0x7C56029f6d3C8cF1DeA38a80E9E8B217b773Bd68` |

> Note: the oracle currently uses mock inflation feeds on testnet. Real Pyth CPI/PCE and Truflation integration is the next milestone.

---

## Build & test

```bash
forge install
forge build
forge test
```

---

## Status

Pre-testnet, building in public. Not audited. Do not use with real funds.

