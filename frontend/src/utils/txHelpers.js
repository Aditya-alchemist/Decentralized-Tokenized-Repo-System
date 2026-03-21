import { erc20Abi } from 'viem';
import { encodeFunctionData } from 'viem';

export async function detectWalletBatchSupport(walletClient, chainId) {
  if (!walletClient || !walletClient.account || !chainId) {
    return {
      status: 'unavailable',
      label: 'Wallet not connected',
      detail: 'Connect a wallet on Sepolia to test batched calls.',
    };
  }

  const chainHex = `0x${chainId.toString(16)}`;

  try {
    const capabilities = await walletClient.request({
      method: 'wallet_getCapabilities',
      params: [walletClient.account.address],
    });

    const chainCapabilities = capabilities?.[chainHex] || capabilities?.[String(chainId)] || capabilities;
    const sendCallsCapability = chainCapabilities?.wallet_sendCalls;
    const supported = Boolean(
      sendCallsCapability === true ||
      sendCallsCapability?.supported === true ||
      sendCallsCapability?.status === 'supported'
    );

    if (supported) {
      return {
        status: 'supported',
        label: 'Single-confirmation flow available',
        detail: 'Wallet advertises wallet_sendCalls support.',
      };
    }

    return {
      status: 'unsupported',
      label: 'Fallback flow likely',
      detail: 'Wallet capabilities do not advertise wallet_sendCalls.',
    };
  } catch (error) {
    return {
      status: 'unknown',
      label: 'Capability unknown',
      detail: error?.shortMessage || error?.message || 'wallet_getCapabilities not available',
    };
  }
}

export async function approveAndExecute({
  walletClient,
  chainId,
  writeContractAsync,
  publicClient,
  tokenAddress,
  spender,
  amount,
  targetAddress,
  targetAbi,
  functionName,
  args,
}) {
  const contracts = [
    {
      address: tokenAddress,
      abi: erc20Abi,
      functionName: 'approve',
      args: [spender, amount],
    },
    {
      address: targetAddress,
      abi: targetAbi,
      functionName,
      args,
    },
  ];

  try {
    if (!walletClient || !chainId) {
      throw new Error('No wallet send-calls support available');
    }

    const calls = contracts.map((c) => ({
      to: c.address,
      data: encodeFunctionData({
        abi: c.abi,
        functionName: c.functionName,
        args: c.args,
      }),
    }));

    await walletClient.request({
      method: 'wallet_sendCalls',
      params: [
        {
          chainId: `0x${chainId.toString(16)}`,
          from: walletClient.account.address,
          calls,
        },
      ],
    });

    return { mode: 'multicall', hash: null, fallbackReason: null };
  } catch (error) {
    const fallbackReason = error?.shortMessage || error?.message || 'wallet_sendCalls failed';

    const approveHash = await writeContractAsync(contracts[0]);
    await publicClient.waitForTransactionReceipt({ hash: approveHash });

    const actionHash = await writeContractAsync(contracts[1]);
    await publicClient.waitForTransactionReceipt({ hash: actionHash });

    return { mode: 'sequential', hash: actionHash, fallbackReason };
  }
}
