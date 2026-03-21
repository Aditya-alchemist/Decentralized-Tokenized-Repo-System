import bondPriceOracleAbi from '../abis/generated/BondPriceOracle.json';
import lendingPoolAbi from '../abis/generated/LendingPool.json';
import marginEngineAbi from '../abis/generated/MarginEngine.json';
import mockTbillAbi from '../abis/generated/MockTBill.json';
import mockUsdcAbi from '../abis/generated/MockUSDC.json';
import repoPoolTokenAbi from '../abis/generated/RepoPoolToken.json';
import repoSettlementAbi from '../abis/generated/RepoSettlement.json';
import repoVaultAbi from '../abis/generated/RepoVault.json';

export const CONTRACTS = {
  mockTbill: {
    address: '0x7B2a668e288bc8f668B709ac5558B851Cf54B113',
    abi: mockTbillAbi,
  },
  mockUsdc: {
    address: '0x38C56C2E22D316249BdCF8C521FEF65d5D8573b8',
    abi: mockUsdcAbi,
  },
  repoPoolToken: {
    address: '0x90e48C8116b69dA6A2f353940A85829c3997aD65',
    abi: repoPoolTokenAbi,
  },
  oracle: {
    address: '0xACc9099c4e9f797f1b96559007BB2a0E0A20368A',
    abi: bondPriceOracleAbi,
  },
  repoVault: {
    address: '0x2175633Fd0bd9D172ee36A6755e8F6A99301a347',
    abi: repoVaultAbi,
  },
  lendingPool: {
    address: '0x3786c0952F33814A96F57a1Ee75c265E5F80e247',
    abi: lendingPoolAbi,
  },
  marginEngine: {
    address: '0x206e609B5CB8bf43FFD1ac1723bFFBd71cb99267',
    abi: marginEngineAbi,
  },
  repoSettlement: {
    address: '0x14038cB88dc2CB86A40e1f0B79E5898aAacc1935',
    abi: repoSettlementAbi,
  },
};

export const SYSTEM_STATUS = [
  { name: 'LendingPool', address: CONTRACTS.lendingPool.address },
  { name: 'RepoVault', address: CONTRACTS.repoVault.address },
  { name: 'MarginEngine', address: CONTRACTS.marginEngine.address },
  { name: 'Oracle', address: CONTRACTS.oracle.address },
];
