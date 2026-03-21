# Wallet Test Matrix

## Scope

Validate batched approve+action behavior and fallback behavior for:

- Deposit (Approve + Deposit)
- Open Repo (Approve + Open Repo)
- Repay Repo (Approve + Repay)
- Meet Margin Call (Approve + Meet Margin)

## Expected UX Rules

- If wallet supports `wallet_sendCalls`, app should show:
  - Header badge: `Batch Calls: Single-confirmation flow available`
  - Success toast wording: `single-confirmation batched flow`
- If wallet does not support `wallet_sendCalls`, app should show:
  - Header badge: `Batch Calls: Fallback flow likely` or `Capability unknown`
  - Success toast wording: `fallback flow (...)`
  - Two wallet confirmations (approve then action)

## Matrix

| Wallet | Network | Header Batch Badge | Deposit Flow | Open Repo Flow | Repay Flow | Meet Margin Flow | Notes |
|---|---|---|---|---|---|---|---|
| MetaMask Extension | Sepolia |  |  |  |  |  |  |
| Coinbase Wallet Extension | Sepolia |  |  |  |  |  |  |
| WalletConnect Mobile | Sepolia |  |  |  |  |  |  |

## Procedure

1. Run frontend with `npm run dev`.
2. Connect one wallet and switch to Sepolia.
3. Open Admin page and click `Re-run Wallet Capability Check`.
4. Record header batch badge value.
5. Execute each approve-required action once using small values.
6. Record whether the wallet prompted once or twice.
7. Confirm success toast wording matches actual flow.
8. Repeat for each wallet type.

## Pass Criteria

- No failed transactions in normal path.
- Header badge and toast messaging match actual behavior.
- Fallback mode succeeds even when batching is unsupported.
