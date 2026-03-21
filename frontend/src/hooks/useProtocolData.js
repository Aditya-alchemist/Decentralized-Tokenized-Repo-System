import { useEffect, useMemo, useState } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import { formatUnits } from 'viem';
import { erc20Abi } from 'viem';
import { CONTRACTS } from '../config/contracts';

const HISTORY_STORAGE_KEY = 'trs_chart_history_v2';
const LIVE_REFETCH_MS = 5000;
const RPUSDC_DECIMALS = 6;

const EMPTY_HISTORY = {
  poolLiquidity: [],
  oraclePrice: [],
  sharePrice: [],
  netWorth: [],
  yield: [],
  ltv: [],
};

function loadPersistedHistory() {
  if (typeof window === 'undefined') {
    return EMPTY_HISTORY;
  }

  try {
    const raw = window.localStorage.getItem(HISTORY_STORAGE_KEY);
    if (!raw) return EMPTY_HISTORY;
    const parsed = JSON.parse(raw);

    return {
      poolLiquidity: Array.isArray(parsed.poolLiquidity) ? parsed.poolLiquidity : [],
      oraclePrice: Array.isArray(parsed.oraclePrice) ? parsed.oraclePrice : [],
      sharePrice: Array.isArray(parsed.sharePrice) ? parsed.sharePrice : [],
      netWorth: Array.isArray(parsed.netWorth) ? parsed.netWorth : [],
      yield: Array.isArray(parsed.yield) ? parsed.yield : [],
      ltv: Array.isArray(parsed.ltv) ? parsed.ltv : [],
    };
  } catch {
    return EMPTY_HISTORY;
  }
}

function asRepo(raw) {
  if (!raw) return null;
  if (Array.isArray(raw)) {
    return {
      borrower: raw[0],
      collateralAmount: raw[1],
      loanAmount: raw[2],
      repoRateBps: raw[3],
      haircutBps: raw[4],
      openedAt: raw[5],
      maturityDate: raw[6],
      termDays: raw[7],
      isActive: raw[8],
      marginCallActive: raw[9],
      marginCallDeadline: raw[10],
    };
  }
  return raw;
}

function toNumber(value, decimals = 0) {
  if (value === undefined || value === null) return 0;
  try {
    if (typeof value === 'bigint') {
      return Number(formatUnits(value, decimals));
    }
    return Number(value);
  } catch {
    return 0;
  }
}

function pushPoint(arr, point, max = 30) {
  const last = arr[arr.length - 1];
  if (last && last.ts === point.ts) {
    const replaced = [...arr.slice(0, -1), point];
    return replaced;
  }

  const next = [...arr, point];
  if (next.length > max) {
    return next.slice(next.length - max);
  }
  return next;
}

export function useProtocolData(address) {
  const [history, setHistory] = useState(loadPersistedHistory);

  const { data: baseReads } = useReadContracts({
    allowFailure: true,
    query: { refetchInterval: LIVE_REFETCH_MS },
    contracts: [
      {
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'availableLiquidity',
      },
      {
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'totalPoolValue',
      },
      {
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'totalLoaned',
      },
      {
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'sharePrice',
      },
      {
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'defaultRepoRateBps',
      },
      {
        address: CONTRACTS.oracle.address,
        abi: CONTRACTS.oracle.abi,
        functionName: 'getLatestPrice',
      },
      {
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'nextRepoId',
      },
      {
        address: CONTRACTS.oracle.address,
        abi: CONTRACTS.oracle.abi,
        functionName: 'getLastUpdated',
      },
    ],
  });

  const nextRepoId = Number(baseReads?.[6]?.result ?? 0n);

  const repoContracts = useMemo(() => {
    const contracts = [];
    for (let i = 0; i < nextRepoId; i += 1) {
      contracts.push({
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'getRepo',
        args: [i],
      });
      contracts.push({
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'getTotalOwed',
        args: [i],
      });
    }
    return contracts;
  }, [nextRepoId]);

  const { data: repoReads } = useReadContracts({
    allowFailure: true,
    query: { refetchInterval: LIVE_REFETCH_MS, enabled: repoContracts.length > 0 },
    contracts: repoContracts,
  });

  const { data: borrowerRepoIds } = useReadContract({
    address: CONTRACTS.repoVault.address,
    abi: CONTRACTS.repoVault.abi,
    functionName: 'getBorrowerRepos',
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address), refetchInterval: LIVE_REFETCH_MS },
  });

  const userRepoIdList = useMemo(() => {
    if (!borrowerRepoIds) return [];
    return borrowerRepoIds.map((x) => Number(x));
  }, [borrowerRepoIds]);

  const userRepoContracts = useMemo(() => {
    const contracts = [];
    userRepoIdList.forEach((id) => {
      contracts.push({
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'getRepo',
        args: [id],
      });
      contracts.push({
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'getTotalOwed',
        args: [id],
      });
      contracts.push({
        address: CONTRACTS.repoVault.address,
        abi: CONTRACTS.repoVault.abi,
        functionName: 'getCollateralValue',
        args: [id],
      });
    });
    return contracts;
  }, [userRepoIdList]);

  const { data: userRepoReads } = useReadContracts({
    allowFailure: true,
    query: { enabled: userRepoContracts.length > 0, refetchInterval: LIVE_REFETCH_MS },
    contracts: userRepoContracts,
  });

  const { data: userReads } = useReadContracts({
    allowFailure: true,
    query: { enabled: Boolean(address), refetchInterval: LIVE_REFETCH_MS },
    contracts: address
      ? [
          {
            address: CONTRACTS.mockUsdc.address,
            abi: erc20Abi,
            functionName: 'balanceOf',
            args: [address],
          },
          {
            address: CONTRACTS.mockTbill.address,
            abi: erc20Abi,
            functionName: 'balanceOf',
            args: [address],
          },
          {
            address: CONTRACTS.repoPoolToken.address,
            abi: erc20Abi,
            functionName: 'balanceOf',
            args: [address],
          },
          {
            address: CONTRACTS.lendingPool.address,
            abi: CONTRACTS.lendingPool.abi,
            functionName: 'getLenderBalance',
            args: [address],
          },
        ]
      : [],
  });

  const globalRepos = useMemo(() => {
    const repos = [];
    for (let i = 0; i < nextRepoId; i += 1) {
      const repoRaw = repoReads?.[i * 2]?.result;
      const totalOwed = repoReads?.[i * 2 + 1]?.result ?? 0n;
      const repo = asRepo(repoRaw);
      if (!repo) continue;

      const collateral = toNumber(repo.collateralAmount, 18);
      const loan = toNumber(repo.loanAmount, 6);
      const totalOwedUsd = toNumber(totalOwed, 6);
      repos.push({
        id: i,
        borrower: repo.borrower,
        collateral,
        collateralRaw: repo.collateralAmount,
        loan,
        loanRaw: repo.loanAmount,
        totalOwedUsd,
        totalOwedRaw: totalOwed,
        openedAt: Number(repo.openedAt ?? 0n),
        maturityDate: Number(repo.maturityDate ?? 0n),
        termDays: Number(repo.termDays ?? 0n),
        isActive: Boolean(repo.isActive),
        marginCallActive: Boolean(repo.marginCallActive),
        marginCallDeadline: Number(repo.marginCallDeadline ?? 0n),
      });
    }
    return repos;
  }, [nextRepoId, repoReads]);

  const userRepos = useMemo(() => {
    const rows = [];
    userRepoIdList.forEach((id, idx) => {
      const repoRaw = userRepoReads?.[idx * 3]?.result;
      const totalOwed = userRepoReads?.[idx * 3 + 1]?.result ?? 0n;
      const collateralValue = userRepoReads?.[idx * 3 + 2]?.result ?? 0n;
      const repo = asRepo(repoRaw);
      if (!repo) return;

      const loanUsd = toNumber(repo.loanAmount, 6);
      const collateralValueUsd = toNumber(collateralValue, 6);
      const ltv = collateralValueUsd > 0 ? (loanUsd / collateralValueUsd) * 100 : 0;
      rows.push({
        id,
        collateral: toNumber(repo.collateralAmount, 18),
        collateralRaw: repo.collateralAmount,
        collateralValue: collateralValueUsd,
        loan: loanUsd,
        loanRaw: repo.loanAmount,
        totalOwed: toNumber(totalOwed, 6),
        totalOwedRaw: totalOwed,
        ltv,
        openedAt: Number(repo.openedAt ?? 0n),
        maturityDate: Number(repo.maturityDate ?? 0n),
        termDays: Number(repo.termDays ?? 0n),
        isActive: Boolean(repo.isActive),
        marginCallActive: Boolean(repo.marginCallActive),
        marginCallDeadline: Number(repo.marginCallDeadline ?? 0n),
      });
    });
    return rows;
  }, [userRepoIdList, userRepoReads]);

  const stats = useMemo(() => {
    const available = toNumber(baseReads?.[0]?.result, 6);
    const poolValue = toNumber(baseReads?.[1]?.result, 6);
    const loaned = toNumber(baseReads?.[2]?.result, 6);
    const sharePrice = toNumber(baseReads?.[3]?.result, 6);
    const defaultRateBps = toNumber(baseReads?.[4]?.result, 0);
    const oraclePrice = toNumber(baseReads?.[5]?.result, 8);
    const totalUsers = new Set(globalRepos.map((repo) => repo.borrower?.toLowerCase())).size;
    const activeRepos = globalRepos.filter((repo) => repo.isActive).length;

    return {
      available,
      poolValue,
      loaned,
      sharePrice,
      oraclePrice,
      nextRepoId,
      activeRepos,
      totalUsers,
      defaultRatePct: defaultRateBps / 100,
      oracleUpdatedAt: Number(baseReads?.[7]?.result ?? 0n),
    };
  }, [baseReads, globalRepos, nextRepoId]);

  const user = useMemo(() => {
    const usdcBalance = toNumber(userReads?.[0]?.result, 6);
    const tbillBalance = toNumber(userReads?.[1]?.result, 18);
    // rpUSDC is minted/burned in USDC base units (6 dp) in this deployment.
    const rpUsdcBalance = toNumber(userReads?.[2]?.result, RPUSDC_DECIMALS);

    const lenderTuple = userReads?.[3]?.result;
    const sharesRaw = lenderTuple?.[0] ?? 0n;
    const lenderValueRaw = lenderTuple?.[1] ?? 0n;
    const lenderValue = toNumber(lenderValueRaw, 6);

    return {
      usdcBalance,
      tbillBalance,
      rpUsdcBalance,
      lenderShares: toNumber(sharesRaw, RPUSDC_DECIMALS),
      lenderValue,
      repos: userRepos,
    };
  }, [userReads, userRepos]);

  useEffect(() => {
    if (!stats.poolValue && !stats.oraclePrice) return;
    const now = new Date();
    const stamp = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const ts = now.getTime();
    const activeLiabilities = user.repos
      .filter((row) => row.isActive)
      .reduce((acc, row) => acc + row.totalOwed, 0);
    const netWorth = user.usdcBalance + user.lenderValue + (user.tbillBalance * stats.oraclePrice) - activeLiabilities;
    const activeRepos = user.repos.filter((row) => row.isActive);
    const ltv0 = activeRepos[0] ? Number(activeRepos[0].ltv.toFixed(2)) : null;
    const ltv1 = activeRepos[1] ? Number(activeRepos[1].ltv.toFixed(2)) : null;

    setHistory((prev) => ({
      poolLiquidity: pushPoint(prev.poolLiquidity, {
        ts,
        time: stamp,
        available: Number(stats.available.toFixed(2)),
        loaned: Number(stats.loaned.toFixed(2)),
      }),
      oraclePrice: pushPoint(prev.oraclePrice, {
        ts,
        time: stamp,
        price: Number(stats.oraclePrice.toFixed(4)),
      }),
      sharePrice: pushPoint(prev.sharePrice, {
        ts,
        time: stamp,
        price: Number(stats.sharePrice.toFixed(6)),
      }),
      netWorth: pushPoint(prev.netWorth, {
        ts,
        time: stamp,
        value: Number(netWorth.toFixed(2)),
      }),
      yield: pushPoint(prev.yield, {
        ts,
        time: stamp,
        yield: Number((Math.max(user.lenderValue - user.lenderShares, 0)).toFixed(4)),
      }),
      ltv: pushPoint(prev.ltv, {
        ts,
        time: stamp,
        repo0: ltv0,
        repo1: ltv1,
      }),
    }));
  }, [
    stats.available,
    stats.loaned,
    stats.oraclePrice,
    stats.poolValue,
    stats.sharePrice,
    user.lenderShares,
    user.lenderValue,
    user.repos,
    user.usdcBalance,
    user.tbillBalance,
  ]);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(history));
    } catch {
      // Ignore storage errors; live charts continue to work in-memory.
    }
  }, [history]);

  return {
    stats,
    user,
    globalRepos,
    charts: {
      poolLiquidity: history.poolLiquidity,
      oraclePrice: history.oraclePrice,
      sharePrice: history.sharePrice,
      netWorth: history.netWorth,
      userYield: history.yield,
      ltv: history.ltv,
    },
  };
}
