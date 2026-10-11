const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(new URL('../../site/app.js', `file://${__filename}`), 'utf8');
const UNIT = 10n ** 18n;

async function page({ allowance = 0n, rejectApproval = false, rejectQuote = false } = {}) {
  const nodes = new Map();
  const calls = [];
  let approved = allowance;
  const element = (id) => {
    if (!nodes.has(id)) nodes.set(id, {
      value: '', textContent: '', hidden: false, listeners: {},
      addEventListener(type, fn) { this.listeners[type] = fn; },
      appendChild() {},
    });
    return nodes.get(id);
  };
  const token = {
    name: async () => 'BMC Illuminati', symbol: async () => 'BMC', decimals: async () => 18,
    totalSupply: async () => 1_000_000_000n * UNIT, INITIAL_SUPPLY: async () => 1_000_000_000n * UNIT,
    balanceOf: async () => 1_000n * UNIT,
    allowance: async () => { calls.push('allowance'); return approved; },
    approve: async (spender, amount) => {
      calls.push(['approve', spender, amount]);
      if (rejectApproval) throw new Error('Approval declined');
      return { wait: async () => { calls.push('approval mined'); approved = amount; } };
    },
  };
  const hook = {
    totalEthFeesPaid: async () => 0n, totalTokensBurned: async () => 0n,
    poolId: async () => 'pool', feeRecipient: async () => 'community',
  };
  const sell = async (key, amount, minimum) => {
    calls.push(['sell', amount, minimum]);
    assert.ok(approved >= amount);
    approved -= amount;
    return { hash: 'test-transaction', wait: async () => { calls.push('sale mined'); } };
  };
  sell.staticCall = async (key, amount) => {
    calls.push('quote');
    if (approved < amount) throw new Error('ERC20InsufficientAllowance');
    if (rejectQuote) throw new Error('Partial fill');
    return UNIT / 100n;
  };
  const cfg = {
    token: 'token', hook: 'hook', router: 'router', chainId: 1, chainName: 'Ethereum',
    communityWallet: 'community', explorer: 'explorer', pool: { fee: 12500, tickSpacing: 60 },
  };
  const ethers = {
    Contract: function (address) { return { token, hook, router: { sellExactIn: sell } }[address]; },
    JsonRpcProvider: function () { return { getBalance: async () => UNIT }; },
    BrowserProvider: function () {
      return { send: async () => {}, getNetwork: async () => ({ chainId: 1n }),
        getSigner: async () => ({ getAddress: async () => 'holder' }) };
    },
    formatUnits: (amount) => String(Number(amount) / 1e18),
    parseUnits: (amount) => BigInt(amount) * UNIT,
  };
  await vm.runInNewContext(source, {
    window: { ethers, ethereum: {} },
    document: { getElementById: element, querySelectorAll: () => [], createElement: () => ({}) },
    fetch: async () => ({ json: async () => cfg }), setInterval() {}, console,
  });
  await element('connect').listeners.click();
  element('sell-bmc').value = '1000';
  element('sell-slip').value = '1';
  const submit = () => element('sell-form').listeners.submit({ preventDefault() {} });
  const input = () => element('sell-bmc').listeners.input();
  return { calls, element, submit, input };
}

test('first sale approves the exact amount, waits, quotes, then sells with slippage', async () => {
  const p = await page();
  await p.submit();
  assert.deepEqual(p.calls, ['allowance', ['approve', 'router', 1_000n * UNIT], 'approval mined',
    'quote', ['sell', 1_000n * UNIT, 99n * UNIT / 10_000n], 'sale mined']);
  assert.match(p.element('trade-status').textContent, /^Sold\./);
});

test('typing without allowance explains approval instead of attempting a doomed quote', async () => {
  const p = await page();
  await p.input();
  assert.deepEqual(p.calls, ['allowance']);
  assert.match(p.element('sell-quote').textContent, /approv/i);
  assert.doesNotMatch(p.element('sell-quote').textContent, /Could not quote/);
});

test('an existing exact allowance can quote and sell without a new approval', async () => {
  const p = await page({ allowance: 1_000n * UNIT });
  await p.submit();
  assert.deepEqual(p.calls, ['allowance', 'quote', ['sell', 1_000n * UNIT, 99n * UNIT / 10_000n], 'sale mined']);
});

test('insufficient existing allowance is replaced with the exact amount', async () => {
  const p = await page({ allowance: 10n * UNIT });
  await p.submit();
  assert.deepEqual(p.calls[1], ['approve', 'router', 1_000n * UNIT]);
  assert.ok(p.calls.includes('sale mined'));
});

test('a declined approval does not quote or submit a sale', async () => {
  const p = await page({ rejectApproval: true });
  await p.submit();
  assert.equal(p.calls.includes('quote'), false);
  assert.match(p.element('trade-status').textContent, /Approval declined/);
});

test('a failed quote after approval does not submit a sale', async () => {
  const p = await page({ rejectQuote: true });
  await p.submit();
  assert.ok(p.calls.includes('approval mined'));
  assert.equal(p.calls.some(c => Array.isArray(c) && c[0] === 'sell'), false);
  assert.match(p.element('trade-status').textContent, /Partial fill/);
});
