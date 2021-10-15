// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { run, ethers, network } from "hardhat";
import { loadPreviousDeployment, loadOrDeploy, waitForTx } from "./utils";
import { ZERO_ADDRESS } from "./constants";
import dotenv from "dotenv";
const envResult = dotenv.config();

if (envResult.error || !envResult.parsed) {
  throw envResult.error;
}
const env = envResult.parsed;

const GUARDIAN_MULTI_SIG_ADDR =
  env[`${network.name.toUpperCase()}_GOVERNANCE_GUARDIAN`] || ZERO_ADDRESS;

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  console.log("Account balance:", (await deployer.getBalance()).toString());

  const deploymentState = loadPreviousDeployment(network.name);
  const aaveToken = await loadOrDeploy(
    "BendToken",
    [],
    network.name,
    deployer,
    deploymentState,
    { proxy: true }
  );
  const governance = await loadOrDeploy(
    "Governance",
    [0, GUARDIAN_MULTI_SIG_ADDR],
    network.name,
    deployer,
    deploymentState
  );
  const shortTimelockExecutor = await loadOrDeploy(
    "Executor",
    [governance.address, 86400, 432000, 86400, 864000, 50, 19200, 50, 200],
    network.name,
    deployer,
    deploymentState,
    { id: "ShortTimelockExecutor" }
  );
  const longTimelockExecutor = await loadOrDeploy(
    "Executor",
    [
      governance.address,
      604800,
      432000,
      604800,
      864000,
      200,
      64000,
      1500,
      2000,
    ],
    network.name,
    deployer,
    deploymentState,
    { id: "LongTimelockExecutor" }
  );
  waitForTx(
    await governance.authorizeExecutors([
      shortTimelockExecutor.address,
      longTimelockExecutor.address,
    ])
  );
  const ecosystemReserve = await loadOrDeploy(
    "EcosystemReserve",
    [],
    network.name,
    deployer,
    deploymentState,
    { proxy: true, proxyInitializer: false }
  );
  const controllerEcosystemReserve = await loadOrDeploy(
    "ControllerEcosystemReserve",
    [shortTimelockExecutor.address, ecosystemReserve.address],
    network.name,
    deployer,
    deploymentState
  );
  try {
    waitForTx(
      await ecosystemReserve.initialize(controllerEcosystemReserve.address)
    );
  } catch (error) {}

  const stakedToken = await loadOrDeploy(
    "StakedToken",
    [
      aaveToken.address,
      aaveToken.address,
      864000,
      172800,
      ecosystemReserve.address,
      shortTimelockExecutor.address,
      3153600000,
      "Staked AAVE",
      "stkAAVE",
      18,
      ZERO_ADDRESS,
    ],
    network.name,
    deployer,
    deploymentState,
    { proxy: true }
  );

  const governanceStrategy = await loadOrDeploy(
    "GovernanceStrategy",
    [aaveToken.address, stakedToken.address],
    network.name,
    deployer,
    deploymentState
  );
  waitForTx(await governance.setGovernanceStrategy(governanceStrategy.address));
  await loadOrDeploy(
    "StakedTokenIncentivesController",
    [stakedToken.address, shortTimelockExecutor.address],
    network.name,
    deployer,
    deploymentState,
    { proxy: true }
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
