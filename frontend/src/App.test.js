import { render, screen } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import App from './App';
import { queryClient, wagmiConfig } from './config/wallet';

test('renders tokenized repo system header', () => {
  render(
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  );
  expect(screen.getByText(/tokenized repo system/i)).toBeInTheDocument();
});
