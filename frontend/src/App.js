import { useEffect, useMemo, useState } from 'react';
import { Link, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { parseUnits } from 'viem';
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useWalletClient,
  useWriteContract,
} from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import toast, { Toaster } from 'react-hot-toast';
import { CONTRACTS, SYSTEM_STATUS } from './config/contracts';
import { useProtocolData } from './hooks/useProtocolData';
import { approveAndExecute, detectWalletBatchSupport } from './utils/txHelpers';
import './App.css';

const ADMIN_ADDRESS = (process.env.REACT_APP_ADMIN_ADDRESS || '').toLowerCase();
const RPUSDC_DECIMALS = 6;

function usd(value) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 2,
  }).format(value);
}

function shortAddress(address) {
  if (!address) {
    return 'Not connected';
  }
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function ltvTone(ltv) {
  if (ltv < 70) return 'safe';
  if (ltv < 90) return 'warn';
  return 'danger';
}

function capabilityTone(status) {
  if (status === 'supported') return 'safe';
  if (status === 'unsupported') return 'warn';
  if (status === 'unavailable') return 'warn';
  return 'danger';
}

function formatChartTick(value) {
  if (!value) return '';
  const d = new Date(value);
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}



function compactErrorMessage(err, fallback = 'Transaction failed') {
  const raw = String(err?.shortMessage || err?.message || '').replace(/\s+/g, ' ').trim();
  if (!raw) return fallback;

  const lower = raw.toLowerCase();
  if (lower.includes('transaction gas limit too high')) {
    return 'Wallet gas limit is above Sepolia block cap. Reset wallet gas settings and retry.';
  }

  const reason = raw.match(/reason:\s*([^()]+?)(?:\(|$)/i);
  if (reason?.[1]) {
    return reason[1].trim();
  }

  return raw.length > 150 ? `${raw.slice(0, 147)}...` : raw;
}

function normalizeSeries(arr = []) {
  return arr.map((row, idx) => ({
    ...row,
    ts: row.ts ?? idx,
  }));
}

function formatRepoDate(unixSeconds) {
  if (!unixSeconds) return 'N/A';
  try {
    return new Date(unixSeconds * 1000).toLocaleString();
  } catch {
    return 'N/A';
  }
}

function timeAgo(unixSeconds) {
  if (!unixSeconds) return 'unknown time ago';
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - unixSeconds);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function StatCard({ label, value, hint }) {
  return (
    <article className="panel stat-card">
      <p className="eyebrow">{label}</p>
      <h3>{value}</h3>
      <p className="hint">{hint}</p>
    </article>
  );
}

function ChartShell({ title, subtitle, children }) {
  return (
    <section className="panel chart-shell">
      <div className="chart-head">
        <h3>{title}</h3>
        <p>{subtitle}</p>
      </div>
      <div className="chart-body">{children}</div>
    </section>
  );
}

function Header({ isAdmin, batchSupport, lastTxMode }) {
  return (
    <header className="site-header">
      <Link to="/" className="brand-wrap brand-link">
        <div className="brand-orb" aria-hidden="true" />
        <div>
          <p className="brand-mini">On-chain fixed income</p>
          <h1 className="brand-title">Tokenized Repo System</h1>
        </div>
      </Link>
      <nav className="top-nav">
        <NavLink to="/dashboard">Dashboard</NavLink>
        <NavLink to="/lend">Lend</NavLink>
        <NavLink to="/borrow">Borrow</NavLink>
        <NavLink to="/portfolio">Portfolio</NavLink>
        {isAdmin && <NavLink to="/admin">Admin</NavLink>}
      </nav>
      <div className="wallet-row">
        <w3m-network-button />
        <w3m-button />
      </div>
      <div className="status-strip">
        <span className={`status-pill ${capabilityTone(batchSupport.status)}`} title={batchSupport.detail}>
          Batch Calls: {batchSupport.label}
        </span>
        {lastTxMode && (
          <span className={`status-pill ${lastTxMode === 'multicall' ? 'safe' : 'warn'}`}>
            Last Tx: {lastTxMode === 'multicall' ? 'single confirmation' : 'fallback sequential'}
          </span>
        )}
      </div>
    </header>
  );
}

function HomePage() {
  return (
    <section className="home-grid">
      <article className="panel home-hero">
        <p className="home-kicker">Protocol Overview</p>
        <h2 className="home-title">
          Repo<span>Terminal</span>
        </h2>
        <p className="home-subtitle">
          Monitor tokenized fixed-income positions, verify risk posture, and execute repo actions with live on-chain
          certainty.
        </p>
        <div className="home-actions">
          <Link className="retro-btn" to="/dashboard">Start Monitoring</Link>
          <Link className="retro-btn alt" to="/portfolio">Open Activity Log</Link>
        </div>
      </article>

      <section className="home-feature-grid">
        <article className="panel home-feature-card">
          <p className="home-feature-tag">01 Risk Intelligence</p>
          <h3>Collateral Signal Engine</h3>
          <p>Continuously computes LTV and margin pressure from oracle-backed collateral valuation.</p>
        </article>
        <article className="panel home-feature-card">
          <p className="home-feature-tag">02 Settlement Layer</p>
          <h3>Automated Repo Workflows</h3>
          <p>Deposit, borrow, repay, and margin workflows run through wallet-aware transaction orchestration.</p>
        </article>
        <article className="panel home-feature-card">
          <p className="home-feature-tag">03 Audit Trail</p>
          <h3>Persistent On-chain Proof</h3>
          <p>Every critical operation is anchored to contracts for transparent, replayable financial history.</p>
        </article>
      </section>

      <article className="panel home-cta">
        <div>
          <h3>Ready to deploy your strategy?</h3>
          <p>Connect wallet, open the dashboard, and manage lending plus borrowing from one control surface.</p>
        </div>
        <Link className="retro-btn" to="/dashboard">Launch Dashboard</Link>
      </article>
    </section>
  );
}

function DashboardPage({ stats, charts }) {
  return (
    <>
      <section className="metrics-grid">
        <StatCard label="Total Pool Liquidity" value={usd(stats.poolValue)} hint="Live on-chain pool value" />
        <StatCard label="Current tTBILL Price" value={usd(stats.oraclePrice)} hint="BondPriceOracle.getLatestPrice" />
        <StatCard label="Total Users" value={stats.totalUsers.toString()} hint="Unique borrower addresses" />
        <StatCard label="Active Repos" value={stats.activeRepos.toString()} hint="RepoVault active positions" />
        <StatCard label="Total Loaned" value={usd(stats.loaned)} hint="LendingPool.totalLoaned" />
        <StatCard label="Share Price (rpUSDC)" value={`$${stats.sharePrice.toFixed(6)}`} hint="LendingPool.sharePrice" />
      </section>

      <section className="charts-grid two-col">
        <ChartShell title="Pool Liquidity Over Time" subtitle="Polled from live reads">
          <ResponsiveContainer width="100%" height={260}>
            <LineChart data={charts.poolLiquidity}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" />
              <Tooltip labelFormatter={formatChartTick} />
              <Legend />
              <Line type="monotone" dataKey="available" stroke="#14b8ff" strokeWidth={3} dot={false} activeDot={{ r: 5 }} animationDuration={900} />
              <Line type="monotone" dataKey="loaned" stroke="#f952a8" strokeWidth={3} dot={false} activeDot={{ r: 5 }} animationDuration={1200} />
            </LineChart>
          </ResponsiveContainer>
        </ChartShell>

        <ChartShell title="tTBILL Price History" subtitle="Oracle history from runtime polling">
          <ResponsiveContainer width="100%" height={260}>
            <LineChart data={charts.oraclePrice}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" />
              <Tooltip labelFormatter={formatChartTick} />
              <Line type="monotone" dataKey="price" stroke="#ff9d1a" strokeWidth={3} dot={false} activeDot={{ r: 5 }} animationDuration={1100} />
            </LineChart>
          </ResponsiveContainer>
        </ChartShell>
      </section>
    </>
  );
}

function LendPage({ stats, charts, user, onDeposit, onWithdraw }) {
  const [deposit, setDeposit] = useState('');
  const [withdraw, setWithdraw] = useState('');
  const pnl = Math.max(user.lenderValue - user.lenderShares, 0);

  return (
    <section className="split-grid">
      <article className="panel">
        <h2>Your Position</h2>
        <ul className="kv-list">
          <li><span>rpUSDC Balance</span><strong>{user.rpUsdcBalance.toFixed(4)} rpUSDC</strong></li>
          <li><span>USDC Value</span><strong>{usd(user.lenderValue)}</strong></li>
          <li><span>Yield Earned</span><strong>{usd(pnl)}</strong></li>
        </ul>

        <div className="form-grid">
          <div className="mini-panel">
            <h3>Deposit USDC</h3>
            <p className="hint">
              Wallet Balance: <strong>{usd(user.usdcBalance)}</strong>
            </p>
            <input value={deposit} onChange={(e) => setDeposit(e.target.value)} placeholder="Amount" />
            <button className="retro-btn" onClick={() => setDeposit(user.usdcBalance.toFixed(2))}>
              Use Max
            </button>
            <button className="retro-btn" onClick={() => onDeposit(deposit)}>
              Approve + Deposit
            </button>
          </div>
          <div className="mini-panel">
            <h3>Withdraw USDC</h3>
            <input value={withdraw} onChange={(e) => setWithdraw(e.target.value)} placeholder="Shares" />
            <button className="retro-btn alt" onClick={() => onWithdraw(withdraw)}>
              Withdraw
            </button>
          </div>
        </div>

        <div className="pool-stats">
          <p><span>Available Liquidity</span><strong>{usd(stats.available)}</strong></p>
          <p><span>Total Pool Value</span><strong>{usd(stats.poolValue)}</strong></p>
          <p><span>Current APY (base)</span><strong>{stats.defaultRatePct.toFixed(2)}%</strong></p>
        </div>
      </article>

      <article className="panel">
        <ChartShell title="Share Price Growth" subtitle="Live share price polling">
          <ResponsiveContainer width="100%" height={220}>
            <LineChart data={charts.sharePrice}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" />
              <Tooltip labelFormatter={formatChartTick} />
              <Line type="monotone" dataKey="price" stroke="#f952a8" strokeWidth={3} dot={false} activeDot={{ r: 5 }} animationDuration={1000} />
            </LineChart>
          </ResponsiveContainer>
        </ChartShell>

        <ChartShell title="Your Yield Over Time" subtitle="Lender value tracking">
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={charts.userYield}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" />
              <Tooltip labelFormatter={formatChartTick} />
              <Area type="monotone" dataKey="yield" stroke="#14b8ff" fill="#8ce6ff" fillOpacity={0.65} animationDuration={1200} />
            </AreaChart>
          </ResponsiveContainer>
        </ChartShell>
      </article>
    </section>
  );
}

function BorrowPage({ stats, charts, repos, onOpenRepo, onRepayRepo, onMeetMarginCall }) {
  const [collateral, setCollateral] = useState('10');
  const [loan, setLoan] = useState('5000');
  const estCollateral = Number(collateral || 0) * stats.oraclePrice;
  const estMaxLoan = estCollateral * 0.7;
  const loanAmount = Number(loan || 0);
  const liveLTV = estCollateral > 0 ? (loanAmount / estCollateral) * 100 : 0;
  const ltvToneClass = ltvTone(liveLTV);

  return (
    <section className="split-grid">
      <article className="panel">
        <h2>Open New Repo</h2>
        <div className="two-inputs">
          <label>
            Collateral (tTBILL)
            <input value={collateral} onChange={(e) => setCollateral(e.target.value)} />
          </label>
          <label>
            Loan Amount (USDC)
            <input value={loan} onChange={(e) => setLoan(e.target.value)} />
          </label>
        </div>

        <ul className="kv-list">
          <li><span>Est. Collateral Value</span><strong>{usd(estCollateral)}</strong></li>
          <li><span>Est. Max Loan (70%)</span><strong>{usd(estMaxLoan)}</strong></li>
          <li><span>Interest Rate</span><strong>{stats.defaultRatePct.toFixed(2)}%</strong></li>
          <li><span>Live LTV</span><strong className={`ltv-${ltvToneClass}`}>{liveLTV.toFixed(2)}%</strong></li>
        </ul>

        <button className="retro-btn" onClick={() => onOpenRepo(collateral, loan)}>
          Approve + Open Repo
        </button>

        <h3 className="section-title">Your Active Repos</h3>
        <div className="repo-list">
          {repos.filter((x) => x.isActive).map((repo) => {
            const tone = ltvTone(repo.ltv);
            return (
              <article key={repo.id} className={`repo-card ${tone}`}>
                <h4>Repo #{repo.id}</h4>
                <p>Collateral: {repo.collateral.toFixed(4)} tTBILL ({usd(repo.collateralValue)})</p>
                <p>Loan: {usd(repo.loan)}</p>
                <p>Total Owed: {usd(repo.totalOwed)}</p>
                <p>LTV: {repo.ltv.toFixed(2)}%</p>
                <p>Status: {repo.marginCallActive ? 'Margin Call Active' : 'Active'}</p>
                <div className="row-actions">
                  <button className="retro-btn small" onClick={() => onRepayRepo(repo.id, repo.totalOwedRaw)}>Approve + Repay</button>
                  <button className="retro-btn small alt" onClick={() => onMeetMarginCall(repo.id)}>Approve + Meet Margin</button>
                </div>
              </article>
            );
          })}
        </div>
      </article>

      <article className="panel">
        <ChartShell title="LTV History Per Repo" subtitle="User position risk over time">
          <ResponsiveContainer width="100%" height={220}>
            <LineChart data={charts.ltv}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" domain={[0, 100]} />
              <Tooltip labelFormatter={formatChartTick} />
              <Line type="monotone" dataKey="repo0" stroke="#14b8ff" strokeWidth={3} dot={false} connectNulls={false} activeDot={{ r: 5 }} animationDuration={900} />
              <Line type="monotone" dataKey="repo1" stroke="#f952a8" strokeWidth={3} dot={false} connectNulls={false} activeDot={{ r: 5 }} animationDuration={1150} />
            </LineChart>
          </ResponsiveContainer>
        </ChartShell>

        <ChartShell title="Oracle Price Feed" subtitle="Risk input live monitoring">
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={charts.oraclePrice}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" domain={['dataMin - 2', 'dataMax + 2']} />
              <Tooltip labelFormatter={formatChartTick} />
              <Area type="monotone" dataKey="price" stroke="#ff9d1a" fill="#ffd089" fillOpacity={0.65} animationDuration={1200} />
            </AreaChart>
          </ResponsiveContainer>
        </ChartShell>
      </article>
    </section>
  );
}

function PortfolioPage({ address, user, charts, oraclePrice }) {
  const tbillMarkedValue = user.tbillBalance * oraclePrice;
  const activeLiabilities = user.repos
    .filter((row) => row.isActive)
    .reduce((acc, row) => acc + row.totalOwed, 0);
  const netWorth = user.usdcBalance + user.lenderValue + tbillMarkedValue - activeLiabilities;
  const repoHistory = useMemo(() => [...user.repos].sort((a, b) => b.id - a.id), [user.repos]);
  const activeTrades = repoHistory.filter((repo) => repo.isActive).length;
  const closedTrades = repoHistory.length - activeTrades;

  return (
    <section className="split-grid">
      <article className="panel">
        <h2>My Wallet {shortAddress(address)}</h2>

        <h3 className="section-title">Balances</h3>
        <ul className="kv-list">
          <li><span>USDC</span><strong>{usd(user.usdcBalance)}</strong></li>
          <li><span>tTBILL</span><strong>{user.tbillBalance.toFixed(4)} tokens</strong></li>
          <li><span>tTBILL Mark Price</span><strong>{usd(oraclePrice)} / token</strong></li>
          <li><span>tTBILL USD Value</span><strong>{usd(tbillMarkedValue)}</strong></li>
          <li><span>rpUSDC</span><strong>{user.rpUsdcBalance.toFixed(4)} shares</strong></li>
        </ul>

        <h3 className="section-title">Lending Position</h3>
        <ul className="kv-list">
          <li><span>Shares</span><strong>{user.lenderShares.toFixed(4)}</strong></li>
          <li><span>Current Value</span><strong>{usd(user.lenderValue)}</strong></li>
          <li><span>Active Liabilities</span><strong>{usd(activeLiabilities)}</strong></li>
          <li><span>Portfolio Net Worth (USD)</span><strong>{usd(netWorth)}</strong></li>
        </ul>

        <h3 className="section-title">Borrow Positions</h3>
        <div className="history-list">
          {user.repos.length === 0 && <p>No borrow positions yet</p>}
          {repoHistory.map((repo) => (
            <article key={repo.id} className="history-row">
              <p>Repo #{repo.id} | Loan {usd(repo.loan)} | LTV {repo.ltv.toFixed(2)}%</p>
              <p>
                Status: <strong>{repo.isActive ? 'Active' : 'Closed'}</strong>
                {repo.marginCallActive ? ' (Margin call active)' : ''}
              </p>
            </article>
          ))}
        </div>

        <h3 className="section-title">Repo Trading History</h3>
        <div className="history-list">
          <p>
            Total Trades: <strong>{repoHistory.length}</strong> | Active: <strong>{activeTrades}</strong> | Closed:{' '}
            <strong>{closedTrades}</strong>
          </p>

          {repoHistory.length === 0 && <p>No repo trade history yet</p>}

          {repoHistory.map((repo) => (
            <article key={`portfolio-history-${repo.id}`} className="history-row">
              <h4>Repo #{repo.id}</h4>
              <p>Loan: {usd(repo.loan)} | Collateral: {repo.collateral.toFixed(4)} tTBILL</p>
              <p>Total Owed: {usd(repo.totalOwed)} | LTV: {repo.ltv.toFixed(2)}%</p>
              <p>Status: {repo.isActive ? 'Active' : 'Closed'}{repo.marginCallActive ? ' (Margin call active)' : ''}</p>
              <p>Opened: {formatRepoDate(repo.openedAt)} ({timeAgo(repo.openedAt)})</p>
              <p>Maturity: {formatRepoDate(repo.maturityDate)} | Term: {repo.termDays || 0} days</p>
            </article>
          ))}
        </div>
      </article>

      <article className="panel">
        <ChartShell title="Net Worth Over Time" subtitle="USD mark-to-market (wallet + protocol exposure)">
          <ResponsiveContainer width="100%" height={280}>
            <AreaChart data={charts.netWorth}>
              <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
              <XAxis dataKey="ts" stroke="#2d2a26" tickFormatter={formatChartTick} minTickGap={40} />
              <YAxis stroke="#2d2a26" tickFormatter={(v) => usd(Number(v))} />
              <Tooltip labelFormatter={formatChartTick} formatter={(v) => usd(Number(v))} />
              <Area type="monotone" dataKey="value" stroke="#ff9d1a" fill="#ffd089" fillOpacity={0.65} animationDuration={1200} />
            </AreaChart>
          </ResponsiveContainer>
        </ChartShell>
      </article>
    </section>
  );
}

function AdminPage({
  isAdmin,
  oraclePrice,
  onManualOracleUpdate,
  onMintUsdc,
  onMintTbill,
  onGrantKycUsdc,
  onGrantKycTbill,
  batchSupport,
  onRunWalletDiagnostics,
  globalRepos,
}) {
  const [oracleInput, setOracleInput] = useState('');
  const [mintAddress, setMintAddress] = useState('');
  const [usdcAmount, setUsdcAmount] = useState('10000');
  const [tbillAmount, setTbillAmount] = useState('10');
  const [kycAddress, setKycAddress] = useState('');

  const borrowerHealth = useMemo(() => {
    const byBorrower = new Map();
    globalRepos.forEach((repo) => {
      if (!repo.borrower) return;
      const key = repo.borrower.toLowerCase();
      const current = byBorrower.get(key) || {
        borrower: repo.borrower,
        activeRepos: 0,
        totalLoan: 0,
        totalOwed: 0,
        marginCalls: 0,
      };

      if (repo.isActive) {
        current.activeRepos += 1;
        current.totalLoan += repo.loan;
        current.totalOwed += repo.totalOwedUsd;
      }
      if (repo.marginCallActive) current.marginCalls += 1;
      byBorrower.set(key, current);
    });

    return Array.from(byBorrower.values())
      .sort((a, b) => b.totalLoan - a.totalLoan)
      .slice(0, 8)
      .map((row) => ({
        ...row,
        healthScore: Math.max(0, 100 - row.marginCalls * 20 - row.activeRepos * 3),
      }));
  }, [globalRepos]);

  const recentRepos = useMemo(
    () => [...globalRepos].sort((a, b) => b.openedAt - a.openedAt).slice(0, 8),
    [globalRepos]
  );

  if (!isAdmin) {
    return (
      <section className="panel denied">
        <h2>Admin Access Required</h2>
        <p>Connect with deployer wallet to view management controls.</p>
      </section>
    );
  }

  return (
    <section className="admin-grid">
      <article className="panel">
        <h2>Oracle Management</h2>
        <p>Current Price: {usd(oraclePrice)}</p>
        <input value={oracleInput} onChange={(e) => setOracleInput(e.target.value)} placeholder="New oracle price in USD" />
        <button className="retro-btn" onClick={() => onManualOracleUpdate(oracleInput)}>Update Price Manually</button>
      </article>

      <article className="panel">
        <h2>Token Minting</h2>
        <input value={mintAddress} onChange={(e) => setMintAddress(e.target.value)} placeholder="Recipient wallet address" />
        <div className="mint-grid">
          <div className="mini-panel">
            <p className="eyebrow">USDC Minting (6 decimals)</p>
            <input value={usdcAmount} onChange={(e) => setUsdcAmount(e.target.value)} placeholder="USDC amount" />
            <button className="retro-btn" onClick={() => onMintUsdc(mintAddress, usdcAmount)}>
              Mint USDC
            </button>
          </div>
          <div className="mini-panel">
            <p className="eyebrow">tTBILL Minting (18 decimals)</p>
            <input value={tbillAmount} onChange={(e) => setTbillAmount(e.target.value)} placeholder="tTBILL amount" />
            <button className="retro-btn alt" onClick={() => onMintTbill(mintAddress, tbillAmount)}>
              Mint tTBILL
            </button>
          </div>
        </div>
      </article>

      <article className="panel">
        <h2>KYC Management</h2>
        <p>Grant KYC verification to wallets before they can receive tokens.</p>
        <input value={kycAddress} onChange={(e) => setKycAddress(e.target.value)} placeholder="Wallet address to KYC verify" />
        <div className="mint-grid">
          <button className="retro-btn" onClick={() => onGrantKycUsdc(kycAddress)}>
            Grant KYC (USDC)
          </button>
          <button className="retro-btn alt" onClick={() => onGrantKycTbill(kycAddress)}>
            Grant KYC (tTBILL)
          </button>
        </div>
      </article>

      <article className="panel">
        <h2>System Status</h2>
        <ul className="status-list">
          {SYSTEM_STATUS.map((item) => (
            <li key={item.name}>
              <span>{item.name}</span>
              <strong>{shortAddress(item.address)}</strong>
            </li>
          ))}
        </ul>
      </article>

      <article className="panel">
        <h2>Wallet Tx Diagnostics</h2>
        <p>Current status: <strong>{batchSupport.label}</strong></p>
        <p className="hint">{batchSupport.detail}</p>
        <button className="retro-btn alt" onClick={onRunWalletDiagnostics}>
          Re-run Wallet Capability Check
        </button>
      </article>

      <article className="panel">
        <h2>Borrower Health</h2>
        <ResponsiveContainer width="100%" height={240}>
          <BarChart data={borrowerHealth}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d8d2c4" />
            <XAxis dataKey="borrower" tickFormatter={shortAddress} />
            <YAxis />
            <Tooltip formatter={(v, n) => (n === 'totalLoan' ? usd(v) : v)} />
            <Legend />
            <Bar dataKey="totalLoan" fill="#14b8ff" radius={[4, 4, 0, 0]} animationDuration={900} />
            <Bar dataKey="marginCalls" fill="#ff6b6b" radius={[4, 4, 0, 0]} animationDuration={1200} />
          </BarChart>
        </ResponsiveContainer>
      </article>

      <article className="panel">
        <h2>Borrower History</h2>
        <div className="history-list">
          {recentRepos.length === 0 && <p>No repos yet.</p>}
          {recentRepos.map((repo) => {
            const collateralUsd = repo.collateral * oraclePrice;
            const ltv = collateralUsd > 0 ? (repo.loan / collateralUsd) * 100 : 0;

            return (
              <article key={`repo-history-${repo.id}`} className="history-row">
                <h4>Repo #{repo.id}</h4>
                <p>Borrower: {shortAddress(repo.borrower)}</p>
                <p>Collateral: {repo.collateral.toFixed(4)} tTBILL ({usd(collateralUsd)})</p>
                <p>Loan: {usd(repo.loan)}</p>
                <p>Total Owed: {usd(repo.totalOwedUsd)}</p>
                <p>LTV: {ltv.toFixed(2)}%</p>
                <p>Status: {repo.isActive ? 'Active' : 'Closed'}{repo.marginCallActive ? ' (Margin call active)' : ''}</p>
                <p>Opened: {formatRepoDate(repo.openedAt)} ({timeAgo(repo.openedAt)})</p>
                <p>Maturity: {formatRepoDate(repo.maturityDate)} | Term: {repo.termDays || 0} days</p>
              </article>
            );
          })}
        </div>
      </article>
    </section>
  );
}

function App() {
  const queryClient = useQueryClient();
  const { address, chainId } = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const { stats, user, charts, globalRepos } = useProtocolData(address);
  const [lastTxMode, setLastTxMode] = useState(null);
  const [batchSupport, setBatchSupport] = useState({
    status: 'unavailable',
    label: 'Wallet not connected',
    detail: 'Connect wallet on Sepolia to evaluate batched approvals.',
  });

  const displayCharts = useMemo(
    () => ({
      poolLiquidity: normalizeSeries(charts.poolLiquidity),
      oraclePrice: normalizeSeries(charts.oraclePrice),
      sharePrice: normalizeSeries(charts.sharePrice),
      netWorth: normalizeSeries(charts.netWorth),
      userYield: normalizeSeries(charts.userYield),
      ltv: normalizeSeries(charts.ltv),
    }),
    [charts]
  );

  const { data: oracleOwner } = useReadContract({
    address: CONTRACTS.oracle.address,
    abi: CONTRACTS.oracle.abi,
    functionName: 'owner',
    query: { refetchInterval: 60000 },
  });

  const isAdmin = useMemo(() => {
    if (!address) return false;
    if (ADMIN_ADDRESS) return address.toLowerCase() === ADMIN_ADDRESS;
    return address.toLowerCase() === String(oracleOwner || '').toLowerCase();
  }, [address, oracleOwner]);

  useEffect(() => {
    let cancelled = false;

    async function checkSupport() {
      const result = await detectWalletBatchSupport(walletClient, chainId);
      if (!cancelled) {
        setBatchSupport(result);
      }
    }

    checkSupport();
    return () => {
      cancelled = true;
    };
  }, [walletClient, chainId, address]);

  const requireWallet = () => {
    if (!address) {
      toast.error('Connect wallet first');
      return false;
    }
    if (!publicClient) {
      toast.error('Public client not ready');
      return false;
    }
    return true;
  };

  const handleDeposit = async (amountInput) => {
    if (!requireWallet()) return;
    try {
      const amount = parseUnits(String(amountInput || '0'), 6);
      if (amount <= 0n) throw new Error('Invalid amount');

      const result = await approveAndExecute({
        walletClient,
        chainId,
        writeContractAsync,
        publicClient,
        tokenAddress: CONTRACTS.mockUsdc.address,
        spender: CONTRACTS.lendingPool.address,
        amount,
        targetAddress: CONTRACTS.lendingPool.address,
        targetAbi: CONTRACTS.lendingPool.abi,
        functionName: 'deposit',
        args: [amount],
      });
      setLastTxMode(result.mode);
      await queryClient.invalidateQueries();
      toast.success('Deposit completed on-chain');
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || 'Deposit failed');
    }
  };

  const handleWithdraw = async (sharesInput) => {
    if (!requireWallet()) return;
    try {
      const shares = parseUnits(String(sharesInput || '0'), RPUSDC_DECIMALS);
      if (shares <= 0n) throw new Error('Invalid shares');
      const hash = await writeContractAsync({
        address: CONTRACTS.lendingPool.address,
        abi: CONTRACTS.lendingPool.abi,
        functionName: 'withdraw',
        args: [shares],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await queryClient.invalidateQueries();
      toast.success('Withdraw successful');
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || 'Withdraw failed');
    }
  };

  const handleOpenRepo = async (collateralInput, loanInput) => {
    if (!requireWallet()) return;
    try {
      const collateral = parseUnits(String(collateralInput || '0'), 18);
      const loan = parseUnits(String(loanInput || '0'), 6);
      if (collateral <= 0n || loan <= 0n) throw new Error('Invalid values');

      const result = await approveAndExecute({
        walletClient,
        chainId,
        writeContractAsync,
        publicClient,
        tokenAddress: CONTRACTS.mockTbill.address,
        spender: CONTRACTS.repoVault.address,
        amount: collateral,
        targetAddress: CONTRACTS.lendingPool.address,
        targetAbi: CONTRACTS.lendingPool.abi,
        functionName: 'requestRepo',
        args: [collateral, loan],
      });
      setLastTxMode(result.mode);
      await queryClient.invalidateQueries();
      toast.success('Repo opened on-chain');
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || 'Open repo failed');
    }
  };

  const handleRepayRepo = async (repoId, totalOwedRaw) => {
    if (!requireWallet()) return;
    try {
      const result = await approveAndExecute({
        walletClient,
        chainId,
        writeContractAsync,
        publicClient,
        tokenAddress: CONTRACTS.mockUsdc.address,
        spender: CONTRACTS.repoSettlement.address,
        amount: totalOwedRaw,
        targetAddress: CONTRACTS.repoVault.address,
        targetAbi: CONTRACTS.repoVault.abi,
        functionName: 'repayRepo',
        args: [repoId],
      });
      setLastTxMode(result.mode);
      await queryClient.invalidateQueries();

      toast.success(
        result.mode === 'multicall'
          ? `Repay for Repo #${repoId} sent via single-confirmation batched flow`
          : `Repay for Repo #${repoId} completed via two-step flow (${result.fallbackReason || 'wallet batching unavailable'})`
      );
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || `Repay failed for Repo #${repoId}`);
    }
  };

  const handleMeetMarginCall = async (repoId) => {
    if (!requireWallet()) return;
    const addAmount = window.prompt('Additional collateral (tTBILL) to post');
    if (!addAmount) return;
    try {
      const collateral = parseUnits(addAmount, 18);
      const result = await approveAndExecute({
        walletClient,
        chainId,
        writeContractAsync,
        publicClient,
        tokenAddress: CONTRACTS.mockTbill.address,
        spender: CONTRACTS.repoVault.address,
        amount: collateral,
        targetAddress: CONTRACTS.repoVault.address,
        targetAbi: CONTRACTS.repoVault.abi,
        functionName: 'meetMarginCall',
        args: [repoId, collateral],
      });
      setLastTxMode(result.mode);
      await queryClient.invalidateQueries();

      toast.success(
        result.mode === 'multicall'
          ? `Meet margin for Repo #${repoId} sent via single-confirmation batched flow`
          : `Meet margin for Repo #${repoId} completed via two-step flow (${result.fallbackReason || 'wallet batching unavailable'})`
      );
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || 'Meet margin call failed');
    }
  };

  const handleManualOracleUpdate = async (priceInput) => {
    if (!requireWallet()) return;
    try {
      const raw = parseUnits(String(priceInput || '0'), 8);
      if (raw <= 0n) throw new Error('Invalid oracle price');

      const hash = await writeContractAsync({
        address: CONTRACTS.oracle.address,
        abi: CONTRACTS.oracle.abi,
        functionName: 'updatePrice',
        args: [raw],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      toast.success('Manual oracle update successful');
    } catch (err) {
      toast.error(err?.shortMessage || err?.message || 'Oracle update failed');
    }
  };

  const handleRunWalletDiagnostics = async () => {
    const result = await detectWalletBatchSupport(walletClient, chainId);
    setBatchSupport(result);
    if (result.status === 'supported') {
      toast.success(`Wallet diagnostics: ${result.label}`);
    } else if (result.status === 'unknown') {
      toast.error(`Wallet diagnostics: ${result.label}. ${result.detail}`);
    } else {
      toast(`Wallet diagnostics: ${result.label}`);
    }
  };

  const handleMintUsdc = async (to, amountInput) => {
    if (!requireWallet()) return;
    try {
      if (!to || to.length < 40) throw new Error('Invalid recipient address');
      const amount = parseUnits(String(amountInput || '0'), 6);
      if (amount <= 0n) throw new Error('Invalid USDC amount');

      let gas;
      try {
        const estimated = await publicClient.estimateContractGas({
          account: address,
          address: CONTRACTS.mockUsdc.address,
          abi: CONTRACTS.mockUsdc.abi,
          functionName: 'mint',
          args: [to, amount],
        });
        gas = (estimated * 12n) / 10n;
        const networkCap = 16_000_000n;
        if (gas > networkCap) gas = networkCap;
      } catch {
        gas = undefined;
      }

      const hash = await writeContractAsync({
        address: CONTRACTS.mockUsdc.address,
        abi: CONTRACTS.mockUsdc.abi,
        functionName: 'mint',
        args: [to, amount],
        ...(gas ? { gas } : {}),
      });
      await publicClient.waitForTransactionReceipt({ hash });
      toast.success('USDC minted successfully');
    } catch (err) {
      toast.error(compactErrorMessage(err, 'Mint USDC failed'));
    }
  };

  const handleMintTbill = async (to, amountInput) => {
    if (!requireWallet()) return;
    try {
      if (!to || to.length < 40) throw new Error('Invalid recipient address');
      const amount = parseUnits(String(amountInput || '0'), 18);
      if (amount <= 0n) throw new Error('Invalid tTBILL amount');

      let gas;
      try {
        const estimated = await publicClient.estimateContractGas({
          account: address,
          address: CONTRACTS.mockTbill.address,
          abi: CONTRACTS.mockTbill.abi,
          functionName: 'mint',
          args: [to, amount],
        });
        gas = (estimated * 12n) / 10n;
        const networkCap = 16_000_000n;
        if (gas > networkCap) gas = networkCap;
      } catch {
        gas = undefined;
      }

      const hash = await writeContractAsync({
        address: CONTRACTS.mockTbill.address,
        abi: CONTRACTS.mockTbill.abi,
        functionName: 'mint',
        args: [to, amount],
        ...(gas ? { gas } : {}),
      });
      await publicClient.waitForTransactionReceipt({ hash });
      toast.success('tTBILL minted successfully');
    } catch (err) {
      toast.error(compactErrorMessage(err, 'Mint tTBILL failed'));
    }
  };

  const handleGrantKycUsdc = async (kycAddress) => {
    if (!requireWallet()) return;
    try {
      if (!kycAddress || kycAddress.length < 40) throw new Error('Invalid recipient address');

      const hash = await writeContractAsync({
        address: CONTRACTS.mockUsdc.address,
        abi: CONTRACTS.mockUsdc.abi,
        functionName: 'grantKYC',
        args: [kycAddress],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      toast.success(`KYC granted for USDC to ${shortAddress(kycAddress)}`);
    } catch (err) {
      toast.error(compactErrorMessage(err, 'Grant KYC (USDC) failed'));
    }
  };

  const handleGrantKycTbill = async (kycAddress) => {
    if (!requireWallet()) return;
    try {
      if (!kycAddress || kycAddress.length < 40) throw new Error('Invalid recipient address');

      const hash = await writeContractAsync({
        address: CONTRACTS.mockTbill.address,
        abi: CONTRACTS.mockTbill.abi,
        functionName: 'grantKYC',
        args: [kycAddress],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      toast.success(`KYC granted for tTBILL to ${shortAddress(kycAddress)}`);
    } catch (err) {
      toast.error(compactErrorMessage(err, 'Grant KYC (tTBILL) failed'));
    }
  };

  return (
    <div className="app-root">
      <Header
        isAdmin={isAdmin}
        batchSupport={batchSupport}
        lastTxMode={lastTxMode}
      />
      <main className="page-shell">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/dashboard" element={<DashboardPage stats={stats} charts={displayCharts} />} />
          <Route
            path="/lend"
            element={<LendPage stats={stats} charts={displayCharts} user={user} onDeposit={handleDeposit} onWithdraw={handleWithdraw} />}
          />
          <Route
            path="/borrow"
            element={
              <BorrowPage
                stats={stats}
                charts={displayCharts}
                repos={user.repos}
                onOpenRepo={handleOpenRepo}
                onRepayRepo={handleRepayRepo}
                onMeetMarginCall={handleMeetMarginCall}
              />
            }
          />
          <Route path="/portfolio" element={<PortfolioPage address={address} user={user} charts={displayCharts} oraclePrice={stats.oraclePrice} />} />
          <Route
            path="/admin"
            element={
              <AdminPage
                isAdmin={isAdmin}
                oraclePrice={stats.oraclePrice}
                onManualOracleUpdate={handleManualOracleUpdate}
                onMintUsdc={handleMintUsdc}
                onMintTbill={handleMintTbill}
                onGrantKycUsdc={handleGrantKycUsdc}
                onGrantKycTbill={handleGrantKycTbill}
                batchSupport={batchSupport}
                onRunWalletDiagnostics={handleRunWalletDiagnostics}
                globalRepos={globalRepos}
              />
            }
          />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>

      <footer className="site-footer">
        <div className="footer-window">
          <div className="footer-grid">
            <section className="footer-block">
              <h4>Tokenized Repo System</h4>
              <p>On-chain fixed income rails for collateralized repo lending.</p>
            </section>
            <section className="footer-block">
              <h4>Navigation</h4>
              <p>Home</p>
              <p>Dashboard</p>
              <p>Lend / Borrow / Portfolio</p>
            </section>
            <section className="footer-block">
              <h4>Network</h4>
              <p>Sepolia Testnet</p>
              <p>Wallet + on-chain contracts</p>
            </section>
          </div>
          <p className="footer-credit">Made by Aditya for love of decentralized systems</p>
        </div>
      </footer>

      <Toaster
        position="bottom-right"
        containerStyle={{ zIndex: 99999, right: 16, bottom: 16 }}
        toastOptions={{
          duration: 3600,
          style: {
            border: 'none',
            borderRadius: '0',
            background: 'transparent',
            color: 'inherit',
            fontFamily: 'VT323, monospace',
            fontSize: '16px',
            lineHeight: '1.2',
            maxWidth: '380px',
            padding: 0,
            boxShadow: 'none',
          },
        }}
      >
        {(t) => (
          <div className={`toast-row ${t.type === 'error' ? 'toast-error' : 'toast-success'}`}>
            <span className="toast-message">{t.message}</span>
            <button 
              type="button"
              className="toast-close" 
              onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                toast.dismiss(t.id);
              }}
            >
              ×
            </button>
          </div>
        )}
      </Toaster>
    </div>
  );
}

export default App;
