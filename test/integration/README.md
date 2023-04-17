# Integration Tests
These are integration tests that are used to validate interactions with other protocols.

To add a new test, ensure that the name of the contract test file includes `IntegrationTest`. The `forge` test command uses a regex of that string in order to run the `IntegrationTests` with the required mainnet keys etc.

## Purpose
These integration tests are primarily for rapid development and tight feedback loops when building an integration with a third party protocol. They allow you to fork mainnet to replicate state and test future protocol upgrades.

## How to run
Make sure an environment variable `MAINNET_ALCHEMY_API_KEY` is in the namespace where you execute integration test commands:

**Dev mode**
`MAINNET_ALCHEMY_API_KEY=x npm run test:integration`

**Latest mode**
`MAINNET_ALCHEMY_API_KEY=x npm run test:integration:latest`