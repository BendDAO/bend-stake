import {
  ethers,
  ContractTransaction,
  Contract,
  BigNumberish,
  BigNumber,
} from "ethers";
import { expect } from "chai";
import { waitForTx, fastForwardTime, makeBN, timeLatest } from "./utils";
import { signTypedData, SignTypedDataVersion } from "@metamask/eth-sig-util";
import { fromRpcSig, ECDSASignature } from "ethereumjs-util";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
export const buildPermitParams = (
  chainId: number,
  tokenContract: string,
  tokenName: string,
  owner: string,
  spender: string,
  nonce: number,
  deadline: string,
  value: BigNumber | number
) => ({
  types: {
    EIP712Domain: [
      { name: "name", type: "string" },
      { name: "version", type: "string" },
      { name: "chainId", type: "uint256" },
      { name: "verifyingContract", type: "address" },
    ],
    Permit: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  },
  primaryType: "Permit" as const,
  domain: {
    name: tokenName,
    version: "1",
    chainId: chainId,
    verifyingContract: tokenContract,
  },
  message: {
    owner,
    spender,
    value: value.toString(),
    nonce,
    deadline,
  },
});

export const getSignatureFromTypedData = (
  privateKey: string,
  typedData: any
): ECDSASignature => {
  const signature = signTypedData({
    privateKey: Buffer.from(privateKey.substring(2, 66), "hex"),
    data: typedData,
    version: SignTypedDataVersion.V4,
  });
  return fromRpcSig(signature);
};

type AssetConfig = {
  totalStaked: BigNumberish;
  emissionPerSecond: BigNumberish;
};

export async function compareRewardsAtAction(
  stakedToken: Contract,
  userAddress: string,
  actions: () => Promise<ContractTransaction>[],
  shouldReward?: boolean,
  assetConfig?: AssetConfig
) {
  const underlyingAsset = stakedToken.address;
  const rewardsBalanceBefore = await stakedToken.getTotalRewardsBalance(
    userAddress
  );
  // Configure assets of stake token
  const assetConfiguration = assetConfig
    ? {
        ...assetConfig,
        underlyingAsset,
      }
    : {
        emissionPerSecond: "100",
        totalStaked: await stakedToken.totalSupply(),
        underlyingAsset,
      };
  await stakedToken.configureAssets([assetConfiguration]);
  const userBalance = await stakedToken.balanceOf(userAddress);
  // Get index before actions
  const userIndexBefore = await getUserIndex(
    stakedToken,
    userAddress,
    underlyingAsset
  );
  // Dispatch actions that can or not update the user index
  const receipts: ethers.ContractReceipt[] = await Promise.all(
    actions().map(async (action) => await waitForTx(await action))
  );

  // Get index after actions
  const userIndexAfter = await getUserIndex(
    stakedToken,
    userAddress,
    underlyingAsset
  );
  // Compare calculated JS rewards versus Solidity user rewards
  const rewardsBalanceAfter = await stakedToken.getTotalRewardsBalance(
    userAddress
  );

  const expectedAccruedRewards = getRewards(
    userBalance,
    userIndexAfter,
    userIndexBefore
  );

  expect(rewardsBalanceAfter).to.eq(
    rewardsBalanceBefore.add(expectedAccruedRewards)
  );
  // Explicit check rewards when the test case expects rewards to the user
  if (shouldReward) {
    expect(expectedAccruedRewards).to.be.gt(0);
  } else {
    expect(expectedAccruedRewards).to.be.eq(0);
    expect(rewardsBalanceAfter).to.be.eq(rewardsBalanceBefore);
  }
}

export function getRewards(
  balance: BigNumber,
  assetIndex: BigNumber,
  userIndex: BigNumber,
  precision: number = 18
) {
  return balance.mul(assetIndex.sub(userIndex)).div(makeBN(1, precision));
}

export async function getUserIndex(
  distributionManager: Contract,
  user: string,
  asset: string
) {
  return await distributionManager.getUserAssetData(user, asset);
}

export async function compareRewardsAtTransfer(
  stakedToken: Contract,
  from: SignerWithAddress,
  to: SignerWithAddress,
  amount: BigNumberish,
  fromShouldReward?: boolean,
  toShouldReward?: boolean,
  assetConfig?: AssetConfig
) {
  const fromAddress = from.address;
  const toAddress = to.address;
  const underlyingAsset = stakedToken.address;

  const fromSavedBalance = await stakedToken.balanceOf(fromAddress);
  const toSavedBalance = await stakedToken.balanceOf(toAddress);
  const fromSavedRewards = await stakedToken.getTotalRewardsBalance(
    fromAddress
  );
  const toSavedRewards = await stakedToken.getTotalRewardsBalance(toAddress);

  // Configure assets of stake token
  const assetConfiguration = assetConfig
    ? {
        ...assetConfig,
        underlyingAsset,
      }
    : {
        emissionPerSecond: "100",
        totalStaked: await stakedToken.totalSupply(),
        underlyingAsset,
      };
  await stakedToken.configureAssets([assetConfiguration]);

  // Get index before actions
  const fromIndexBefore = await getUserIndex(
    stakedToken,
    fromAddress,
    underlyingAsset
  );
  const toIndexBefore = await getUserIndex(
    stakedToken,
    toAddress,
    underlyingAsset
  );

  // Load actions that can or not update the user index
  await waitForTx(await stakedToken.connect(from).transfer(toAddress, amount));

  // Check rewards after transfer

  // Get index after actions
  const fromIndexAfter = await getUserIndex(
    stakedToken,
    fromAddress,
    underlyingAsset
  );
  const toIndexAfter = await getUserIndex(
    stakedToken,
    toAddress,
    underlyingAsset
  );

  // FROM: Compare calculated JS rewards versus Solidity user rewards
  const fromRewardsBalanceAfter = await stakedToken.getTotalRewardsBalance(
    fromAddress
  );
  const fromExpectedAccruedRewards = getRewards(
    fromSavedBalance,
    fromIndexAfter,
    fromIndexBefore
  );
  expect(fromRewardsBalanceAfter).to.eq(
    fromSavedRewards.add(fromExpectedAccruedRewards)
  );

  // TO: Compare calculated JS rewards versus Solidity user rewards
  const toRewardsBalanceAfter = await stakedToken.getTotalRewardsBalance(
    toAddress
  );
  const toExpectedAccruedRewards = getRewards(
    toSavedBalance,
    toIndexAfter,
    toIndexBefore
  );
  expect(toRewardsBalanceAfter).to.eq(
    toSavedRewards.add(toExpectedAccruedRewards)
  );

  // Explicit check rewards when the test case expects rewards to the user
  if (fromShouldReward) {
    expect(fromExpectedAccruedRewards).to.be.gt(0);
  } else {
    expect(fromExpectedAccruedRewards).to.be.eq(0);
  }

  // Explicit check rewards when the test case expects rewards to the user
  if (toShouldReward) {
    expect(toExpectedAccruedRewards).to.be.gt(0);
  } else {
    expect(toExpectedAccruedRewards).to.be.eq(0);
  }

  // Expect new balances
  if (fromAddress === toAddress) {
    expect(fromSavedBalance).to.be.eq(toSavedBalance);
  } else {
    const fromNewBalance = await stakedToken.balanceOf(fromAddress);
    const toNewBalance = await stakedToken.balanceOf(toAddress);
    expect(fromNewBalance).to.be.eq(fromSavedBalance.sub(amount));
    expect(toNewBalance).to.be.eq(toSavedBalance.add(amount));
  }
}