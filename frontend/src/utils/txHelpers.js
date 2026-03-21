import { erc20Abi } from 'viem';
import { encodeFunctionData } from 'viem';

function getFallbackReason(error) {
  const short = String(error?.shortMessage || '').toLowerCase();
  const full = String(error?.message || '').toLowerCase();
  const text = `${short} ${full}`;

  if (text.includes('user rejected')) return 'user rejected wallet batch request';
  if (text.includes('method not found')) return 'wallet does not support batched RPC';
  if (text.includes('invalid parameters')) return 'wallet rejected batch parameters';
  if (text.includes('capabilities')) return 'wallet capability check unavailable';

  return 'wallet batching unavailable';
}

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
    console.log('Starting transaction sequence...');
    console.log('Approve contract:', contracts[0].address);
    console.log('Action contract:', contracts[1].address);
    
    // Use sequential transactions directly - more reliable than batch
    console.log('Sending approve tx...');
    const approveHash = await writeContractAsync(contracts[0]);
    console.log('Approve tx sent:', approveHash);
    
    console.log('Waiting for approve confirmation...');
    await publicClient.waitForTransactionReceipt({ 
      hash: approveHash,
      timeout: 90000,
      pollingInterval: 2000,
    });
    console.log('Approve tx confirmed');

    console.log('Sending action tx...');
    const actionHash = await writeContractAsync(contracts[1]);
    console.log('Action tx sent:', actionHash);
    
    console.log('Waiting for action confirmation...');
    await publicClient.waitForTransactionReceipt({ 
      hash: actionHash,
      timeout: 90000,
      pollingInterval: 2000,
    });
    console.log('Action tx confirmed');

    return { mode: 'sequential', hash: actionHash, fallbackReason: null };
  } catch (error) {
    console.error('Transaction failed:', error);
    console.error('Error message:', error?.message);
    console.error('Error short:', error?.shortMessage);
    throw error;
  }
}
