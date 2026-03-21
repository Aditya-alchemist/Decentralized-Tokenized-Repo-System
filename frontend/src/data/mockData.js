export const dashboardStats = {
  totalPoolLiquidity: 50000,
  currentTbillPrice: 979.63,
  totalUsers: 12,
  totalActiveRepos: 3,
  totalLoaned: 15000,
  sharePrice: '1.0023',
};

export const poolLiquidityHistory = [
  { time: 'Mar 18', available: 42000, loaned: 8000 },
  { time: 'Mar 19', available: 39000, loaned: 11000 },
  { time: 'Mar 20', available: 36000, loaned: 14000 },
  { time: 'Mar 21', available: 35000, loaned: 15000 },
];

export const priceHistory = [
  { time: '02:00', price: 980.12 },
  { time: '08:00', price: 979.92 },
  { time: '14:00', price: 979.63 },
  { time: '20:00', price: 979.78 },
];

export const poolComposition = [
  { name: 'Available', value: 35000, color: '#6da8d6' },
  { name: 'Loaned', value: 15000, color: '#c98bbb' },
  { name: 'Interest Buffer', value: 650, color: '#f1ce6d' },
];

export const rpUsdcHistory = [
  { time: 'Mar 18', price: 1.0 },
  { time: 'Mar 19', price: 1.0009 },
  { time: 'Mar 20', price: 1.0017 },
  { time: 'Mar 21', price: 1.0023 },
];

export const userYieldHistory = [
  { time: 'Mar 18', yield: 0 },
  { time: 'Mar 19', yield: 0.42 },
  { time: 'Mar 20', yield: 0.87 },
  { time: 'Mar 21', yield: 1.15 },
];

export const repoPositions = [
  {
    id: 0,
    collateral: 10,
    collateralValue: 9796,
    loan: 5000,
    totalOwed: 5023,
    ltv: 51.2,
    status: 'Active',
  },
  {
    id: 1,
    collateral: 6,
    collateralValue: 5878,
    loan: 3000,
    totalOwed: 3015,
    ltv: 68.0,
    status: 'Active',
  },
];

export const ltvHistory = [
  { time: '08:00', repo0: 49, repo1: 65 },
  { time: '12:00', repo0: 50, repo1: 66 },
  { time: '16:00', repo0: 51.2, repo1: 68 },
  { time: '20:00', repo0: 51, repo1: 67.8 },
];

export const marginTimeline = [
  { time: '08:00', safe: 1, warn: 0, danger: 0 },
  { time: '12:00', safe: 1, warn: 0, danger: 0 },
  { time: '16:00', safe: 0, warn: 1, danger: 0 },
  { time: '20:00', safe: 0, warn: 1, danger: 0 },
];

export const portfolio = {
  usdc: 10234,
  tbill: 90,
  rpUsdc: 500.23,
  deposited: 50000,
  currentValue: 50023,
  pnl: 23,
};

export const netWorthHistory = [
  { time: 'Mar 18', value: 59750 },
  { time: 'Mar 19', value: 59980 },
  { time: 'Mar 20', value: 60115 },
  { time: 'Mar 21', value: 60340 },
];

export const txHistory = [
  { id: 1, status: 'OK', label: 'Deposited $50,000', time: 'Mar 19 11:00pm' },
  { id: 2, status: 'OK', label: 'Opened Repo #0', time: 'Mar 19 11:10pm' },
  { id: 3, status: 'OK', label: 'Opened Repo #1', time: 'Mar 20 09:00am' },
];

export const systemContracts = [
  { name: 'LendingPool', address: '0x3786c0952F33814A96F57a1Ee75c265E5F80e247' },
  { name: 'RepoVault', address: '0x2175633Fd0bd9D172ee36A6755e8F6A99301a347' },
  { name: 'MarginEngine', address: '0x206e609B5CB8bf43FFD1ac1723bFFBd71cb99267' },
  { name: 'Oracle', address: '0xACc9099c4e9f797f1b96559007BB2a0E0A20368A' },
];
