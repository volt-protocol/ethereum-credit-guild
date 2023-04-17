# Proposal simulation framework

The `contracts/test/proposals` folder contain a testing framework used by Volt Protocol to simulate protocol upgrades.

## Development

To develop new proposals, you must create a new VIP file in `contracts/test/proposals/vips`.

Proposals are organized in 5 steps :

- `deploy()`: Deploy contracts and add them to list of addresses.
- `afterDeploy()`: After deploying, call initializers and link contracts together, e.g. if you deployed `Core` and `Volt` contracts, you could link them in this step by calling `core.setVolt(volt)`.
- `run()`: Actually run the proposal (e.g. queue actions in the Timelock, or execute a serie of Multisig calls...). See `contracts/test/proposals/proposalTypes` for helper contracts.
- `teardown()`: After a proposal executed, if you mocked some behavior in the `afterDeploy()` step, you might want to tear down the mocks here. For instance, in `afterDeploy()` you could impersonate the multisig of another protocol to do actions in their protocol (in anticipation of changes that must happen before your proposal execution), and here you could revert these changes, to make sure the integration tests run on a state that is as close to mainnet as possible.
- `validate()`: For small post-proposal checks, e.g. read state variables of the contracts you deployed, to make sure your `deploy()` and `afterDeploy()` steps have deployed contracts in a correct configuration, or read states that are expected to have change during your `run()` step. Note that there is a set of tests that run post-proposal in `contracts/test/integration/post-proposal-checks`, as well as tests that read state before proposals & after, in `contracts/test/integration/proposal-checks`, so this `validate()` step should only be used for small checks. If you want to add extensive validation of a new component deployed by your proposal, you might want to add a post-proposal test file instead.

Several helpers are available:

- If your proposal is a DAO Timelock action, your proposal should inherit `proposalTypes/TimelockProposal`.
- If your proposal is a Team Multisig action, your proposal should inherit `proposalTypes/MultisigProposal`.

You can perform arbitrary calls, mocks, and impersonations, when you inherit the basic `proposalTypes/Proposal` type.

To launch the simulation of your proposal, add your VIP script to the list of pending proposals in `contracts/test/proposals/TestProposals.sol`, and run `npm run test:proposal:forge`.

After your proposal works, you can run the end-to-end tests to validate that your proposal didn't break anything by running `npm run test:e2e`. See next section for e2e test updates.

## Validation (1)

Make sure to perform some validations in your proposals `validate()` step.

If you introduce changes to the protocol's state, such as granting new roles or breaking existing systems, you will make the proposal integration tests that are located in `contracts/test/integration/post-proposal-checks` and `contracts/test/integration/proposal-checks` fail. Make sure to update these tests, it also allows for an easy code review of the protocol changes you're introducing with your proposal. 

## Deployment

After code review cycles, and the Solidity code is final, now is time to deploy.

To deploy the new contracts of a protocol upgrade, you can use the Forge script located at `contracts/test/proposals/DeployProposal.s.sol`.

After you have deployed the contracts and verified them on Etherescan, you can add the list of deployed addresses and their label in the file located at `contracts/test/proposals/Addresses.sol`.

## Validation (2)
To validate the proposal execution using the contracts you just deployed on a forked mainnet, you can run `DO_DEPLOY=false DO_AFTERDEPLOY=false npm run test:proposal:forge`.

## Execution
The various implementations of the `run()` function print the useful information for executing the proposals on mainnet if you have not set the `DEBUG` environment variable to `false` (by default, the debug prints are shown).

For instance, a `TimelockProposal` will print the calldata to send for queuing the actions to the DAO Timelock.
