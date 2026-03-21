import { QueryClient } from '@tanstack/react-query';
import { createWeb3Modal, defaultWagmiConfig } from '@web3modal/wagmi/react';
import { sepolia } from 'wagmi/chains';

const projectId = process.env.REACT_APP_WALLETCONNECT_PROJECT_ID || 'MISSING_PROJECT_ID';
const chains = [sepolia];

const metadata = {
  name: 'Tokenized Repo System',
  description: 'Tokenized Repo System dApp',
  url: typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3000',
  icons: ['https://avatars.githubusercontent.com/u/37784886'],
};

export const wagmiConfig = defaultWagmiConfig({
  chains,
  projectId,
  metadata,
  ssr: false,
  enableCoinbaseWallet: true,
  enableInjectedWallet: true,
});

export const queryClient = new QueryClient();

createWeb3Modal({
  wagmiConfig,
  projectId,
  chains,
  themeMode: 'light',
  enableEns: false,
  enableOnramp: false,
  themeVariables: {
    '--w3m-accent': '#b06a9f',
    '--w3m-border-radius-master': '2px',
    '--w3m-font-family': 'VT323, monospace',
  },
});
