/* BMC Illuminati site. Plain browser JS on ethers v6. Reads come from a public RPC; writes go through
   the user's injected wallet (window.ethereum). No admin actions exist anywhere in this file. */
(async function main() {
  const { ethers } = window;
  const $ = (id) => document.getElementById(id);
  const ZERO = "0x0000000000000000000000000000000000000000";

  const TOKEN_ABI = [
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function totalSupply() view returns (uint256)",
    "function INITIAL_SUPPLY() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
  ];
  const HOOK_ABI = [
    "function feeRecipient() view returns (address)",
    "function buyFeeBps() view returns (uint256)",
    "function sellBurnBps() view returns (uint256)",
    "function totalEthFeesPaid() view returns (uint256)",
    "function totalTokensBurned() view returns (uint256)",
    "function pendingEthFees() view returns (uint256)",
    "function pendingBurns() view returns (uint256)",
    "function poolId() view returns (bytes32)",
    "function collect()",
  ];
  const ROUTER_ABI = [
    "function buyExactIn((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,uint256 minTokensOut) payable returns (uint256)",
    "function sellExactIn((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,uint256 tokensIn,uint256 minEthOut) returns (uint256)",
  ];

  const cfg = await fetch("config.json").then((r) => r.json());
  const launched = cfg.token && cfg.hook && cfg.router;
  const explorer = (a) => `${cfg.explorer}/address/${a}`;
  const fmt = (v, d = 18, dp = 4) => {
    const s = ethers.formatUnits(v, d);
    const [i, f = ""] = s.split(".");
    return Number(i).toLocaleString("en-US") + (f ? "." + f.slice(0, dp).replace(/0+$/, "") : "").replace(/\.$/, "");
  };

  // Community links
  const linksEl = $("community-links");
  for (const [name, url] of Object.entries(cfg.links || {})) {
    if (!url) continue;
    const a = document.createElement("a");
    a.href = url;
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = name === "x" ? "X / Twitter" : name[0].toUpperCase() + name.slice(1);
    linksEl.appendChild(a);
  }
  $("cw-link").textContent = cfg.communityWallet;
  $("cw-link").href = explorer(cfg.communityWallet);
  $("pool-link").href = cfg.links?.uniswap || "https://app.uniswap.org/explore/pools/ethereum";

  if (!launched) {
    $("launch-notice").hidden = false;
    $("t-address").textContent = "not launched yet";
    $("h-address").textContent = "not launched yet";
    return;
  }

  const readProvider = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId);
  const token = new ethers.Contract(cfg.token, TOKEN_ABI, readProvider);
  const hook = new ethers.Contract(cfg.hook, HOOK_ABI, readProvider);
  const key = {
    currency0: ZERO,
    currency1: cfg.token,
    fee: cfg.pool.fee,
    tickSpacing: cfg.pool.tickSpacing,
    hooks: cfg.hook,
  };

  $("t-address").textContent = cfg.token;
  $("t-address").href = explorer(cfg.token);
  $("h-address").textContent = cfg.hook;
  $("h-address").href = explorer(cfg.hook);

  let decimals = 18;
  let feeRecipient = ZERO;
  async function refreshStats() {
    try {
      const [name, symbol, dec, total, initial, ethPaid, burnedByHook, poolId, recipient] = await Promise.all([
        token.name(), token.symbol(), token.decimals(), token.totalSupply(), token.INITIAL_SUPPLY(),
        hook.totalEthFeesPaid(), hook.totalTokensBurned(), hook.poolId(), hook.feeRecipient(),
      ]);
      decimals = Number(dec);
      feeRecipient = recipient;
      $("t-name").textContent = name;
      $("t-symbol").textContent = symbol;
      $("t-initial").textContent = `${fmt(initial, decimals, 0)} ${symbol}`;
      $("t-total").textContent = `${fmt(total, decimals, 2)} ${symbol}`;
      $("t-burned").textContent = `${fmt(initial - total, decimals, 2)} ${symbol}`;
      $("t-circ").textContent = `${fmt(total, decimals, 2)} ${symbol}`;
      $("h-eth").textContent = `${fmt(ethPaid, 18, 6)} ETH`;
      $("h-burned").textContent = `${fmt(burnedByHook, decimals, 2)} ${symbol}`;
      $("p-id").textContent = cfg.poolId || poolId;
    } catch (e) {
      $("t-total").textContent = "unavailable (RPC error)";
      console.error(e);
    }
  }
  await refreshStats();
  setInterval(refreshStats, 30_000);

  // Wallet
  let signer = null;
  let account = null;
  const status = (el, msg, isError) => { el.textContent = msg; el.className = "small" + (isError ? " error" : ""); };

  async function refreshWallet() {
    if (!account) return;
    const [eth, bmc] = await Promise.all([readProvider.getBalance(account), token.balanceOf(account)]);
    $("w-address").textContent = account;
    $("w-eth").textContent = `${fmt(eth, 18, 6)} ETH`;
    $("w-bmc").textContent = `${fmt(bmc, decimals, 2)} BMC`;
    const isRecipient = account.toLowerCase() === feeRecipient.toLowerCase();
    $("claim-box").hidden = !isRecipient;
    if (isRecipient) {
      const pending = await hook.pendingEthFees();
      status($("claim-status"), `Pending hook ETH claims: ${fmt(pending, 18, 6)} ETH`);
      $("claim-lp").disabled = !(cfg.launcherFeeClaim && cfg.launcherFeeClaim.address && cfg.launcherFeeClaim.method);
      if ($("claim-lp").disabled) $("claim-lp").title = "The LP-fee claim contract is not configured yet.";
    }
  }

  $("connect").addEventListener("click", async () => {
    if (!window.ethereum) { alert("No wallet found. Install MetaMask or another EIP-1193 wallet."); return; }
    const browser = new ethers.BrowserProvider(window.ethereum);
    await browser.send("eth_requestAccounts", []);
    const net = await browser.getNetwork();
    if (Number(net.chainId) !== Number(cfg.chainId)) {
      try {
        await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + Number(cfg.chainId).toString(16) }] });
      } catch (_) { alert(`Please switch your wallet to ${cfg.chainName}.`); return; }
    }
    signer = await browser.getSigner();
    account = await signer.getAddress();
    $("connect").hidden = true;
    $("wallet").hidden = false;
    await refreshWallet();
  });

  // Tabs
  document.querySelectorAll(".tab").forEach((b) => b.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("active", x === b));
    $("buy-form").hidden = b.dataset.tab !== "buy";
    $("sell-form").hidden = b.dataset.tab !== "sell";
  }));

  const routerRead = new ethers.Contract(cfg.router, ROUTER_ABI, readProvider);
  const withSlippage = (amount, pct) => amount - (amount * BigInt(Math.round(Number(pct) * 100))) / 10_000n;

  // Quotes: simulate the router call from the connected (or a zero-balance) account.
  async function quoteBuy(ethIn) {
    const from = account || cfg.communityWallet;
    return routerRead.buyExactIn.staticCall(key, 0, { value: ethIn, from });
  }
  async function quoteSell(tokensIn) {
    if (!account) return null;
    return routerRead.sellExactIn.staticCall(key, tokensIn, 0, { from: account });
  }

  $("buy-eth").addEventListener("input", async () => {
    try {
      const v = $("buy-eth").value.trim();
      if (!v) return status($("buy-quote"), "Enter an amount to see the expected BMC.");
      const out = await quoteBuy(ethers.parseEther(v));
      status($("buy-quote"), `Expected: about ${fmt(out, decimals, 2)} BMC (1% of your ETH goes to the community wallet).`);
    } catch (e) { status($("buy-quote"), "Could not quote: " + (e.shortMessage || e.message), true); }
  });
  $("sell-bmc").addEventListener("input", async () => {
    try {
      const v = $("sell-bmc").value.trim();
      if (!v) return status($("sell-quote"), "Enter an amount to see the expected ETH.");
      if (!account) return status($("sell-quote"), "Connect a wallet holding BMC to quote a sale.");
      const tokensIn = ethers.parseUnits(v, decimals);
      if (await token.allowance(account, cfg.router) < tokensIn) {
        return status($("sell-quote"), "Approve the exact amount using the sell button; the ETH quote follows confirmation.");
      }
      const out = await quoteSell(tokensIn);
      status($("sell-quote"), `Expected: about ${fmt(out, 18, 6)} ETH. 1% of the BMC you sell is burned.`);
    } catch (e) { status($("sell-quote"), "Could not quote: " + (e.shortMessage || e.message), true); }
  });

  $("buy-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (!signer) return status($("trade-status"), "Connect a wallet first.", true);
    try {
      const ethIn = ethers.parseEther($("buy-eth").value.trim());
      const expected = await quoteBuy(ethIn);
      const minOut = withSlippage(expected, $("buy-slip").value || "0");
      status($("trade-status"), "Confirm the buy in your wallet…");
      const router = new ethers.Contract(cfg.router, ROUTER_ABI, signer);
      const tx = await router.buyExactIn(key, minOut, { value: ethIn });
      status($("trade-status"), `Sent ${tx.hash}. Waiting…`);
      await tx.wait();
      status($("trade-status"), `Bought. ${cfg.explorer}/tx/${tx.hash}`);
      await Promise.all([refreshWallet(), refreshStats()]);
    } catch (e) { status($("trade-status"), "Buy failed: " + (e.shortMessage || e.message), true); }
  });

  $("sell-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (!signer) return status($("trade-status"), "Connect a wallet first.", true);
    try {
      const tokensIn = ethers.parseUnits($("sell-bmc").value.trim(), decimals);
      const tokenW = new ethers.Contract(cfg.token, TOKEN_ABI, signer);
      const allowance = await tokenW.allowance(account, cfg.router);
      if (allowance < tokensIn) {
        status($("trade-status"), "Step 1/2: approve exactly the amount you are selling…");
        const a = await tokenW.approve(cfg.router, tokensIn);
        await a.wait();
      }
      // Simulating sellExactIn pulls tokens too, so quote only after the approval is mined.
      const expected = await quoteSell(tokensIn);
      const minOut = withSlippage(expected, $("sell-slip").value || "0");
      status($("trade-status"), "Step 2/2: confirm the sale in your wallet…");
      const router = new ethers.Contract(cfg.router, ROUTER_ABI, signer);
      const tx = await router.sellExactIn(key, tokensIn, minOut);
      status($("trade-status"), `Sent ${tx.hash}. Waiting…`);
      await tx.wait();
      status($("trade-status"), `Sold. ${cfg.explorer}/tx/${tx.hash}`);
      await Promise.all([refreshWallet(), refreshStats()]);
    } catch (e) { status($("trade-status"), "Sell failed: " + (e.shortMessage || e.message), true); }
  });

  $("collect-hook").addEventListener("click", async () => {
    try {
      const h = new ethers.Contract(cfg.hook, HOOK_ABI, signer);
      const tx = await h.collect();
      status($("claim-status"), `Collecting… ${tx.hash}`);
      await tx.wait();
      await Promise.all([refreshWallet(), refreshStats()]);
    } catch (e) { status($("claim-status"), "Collect failed: " + (e.shortMessage || e.message), true); }
  });

  $("claim-lp").addEventListener("click", async () => {
    const c = cfg.launcherFeeClaim;
    try {
      const fees = new ethers.Contract(c.address, c.abi, signer);
      const tx = await fees[c.method](...(c.args || []));
      status($("claim-status"), `Claiming… ${tx.hash}`);
      await tx.wait();
      status($("claim-status"), "Launcher fee share claimed.");
      await refreshWallet();
    } catch (e) { status($("claim-status"), "Claim failed: " + (e.shortMessage || e.message), true); }
  });
})();
