"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale (token)
// Version: 0.0.2 - use sale state
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import { State as SaleState } from '@KinnFoundation/sale#sale-v0.1.11r0:interface.rsh';

// TYPES

export const State = Struct([
  ...Struct.fields(SaleState),
  ["pToken", Token],
]);

export const Params = Object({
  tokenAmount: UInt, // token amount
  price: UInt, // price per token
});

// FUN

const state = Fun([], State);
const buy = Fun([UInt], Null);

// REMOTE FUN

export const rState = (ctc) => {
  const r = remote(ctc, { state });
  return r.state();
};

export const rBuy = (ctc) => {
  const r = remote(ctc, { buy });
  return r.buy();
};

// CONTRACT

export const Event = () => [];
export const Participants = () => [
  Participant("Manager", {
    getParams: Fun([], Params),
    signal: Fun([], Null),
  }),
  Participant("Relay", {}),
];
export const Views = () => [
  View({
    state: State,
  }),
];
export const Api = () => [
  API({
    buy,
    close: Fun([], Null),
    grant: Fun([Address], Null),
    update: Fun([UInt], Null),
  }),
];
export const App = (map) => {
  const [
    { amt, ttl, tok0: token, tok1: pToken },
    [addr, _],
    [Manager, Relay],
    [v],
    [a],
    _,
  ] = map;

  Manager.only(() => {
    const { tokenAmount, price } = declassify(interact.getParams());
  });
  Manager.publish(tokenAmount, price)
    .pay([amt, [tokenAmount, token]])
    .check(() => {
      check(tokenAmount > 0, "tokenAmount must be greater than 0");
      check(price > 0, "price must be greater than 0");
    })
    .timeout(relativeTime(ttl), () => {
      Anybody.publish(); // must be anybody
      transfer([
        [getUntrackedFunds(token), token],
        [getUntrackedFunds(pToken), pToken],
      ]).to(addr);
      commit();
      exit();
    });
  transfer(amt).to(addr);
  Manager.interact.signal();

  const initialState = {
    manager: Manager,
    token,
    tokenAmount,
    pToken,
    price,
    closed: false,
  };

  const [s] = parallelReduce([initialState])
    .define(() => {
      v.state.set(State.fromObject(s));
    })
    // TOKEN BALANCE
    .invariant(
      implies(!s.closed, balance(token) == s.tokenAmount),
      "token balance accurate before close"
    )
    .invariant(
      implies(s.closed, balance(token) == 0),
      "token balance accurate after close"
    )
    // PAYMENT TOKEN BALANCE
    .invariant(balance(pToken) == 0, "payment token balance accurate")
    // BALANCE
    .invariant(balance() == 0, "balance accurate")
    .while(!s.closed)
    .paySpec([pToken])
    // api: update
    //  - update price
    .api_(a.update, (msg) => {
      check(msg > 0, "price must be greater than 0");
      return [
        (k) => {
          k(null);
          return [
            {
              ...s,
              price: msg,
            },
          ];
        },
      ];
    })
    // api: grant
    //  - asign another account as manager
    .api_(a.grant, (msg) => {
      check(this === s.manager);
      return [
        (k) => {
          k(null);
          return [
            {
              ...s,
              manager: msg,
            },
          ];
        },
      ];
    })
    // api: buy
    //  - buy token
    .api_(a.buy, (msg) => {
      check(msg <= s.tokenAmount, "not enough tokens");
      return [
        [0, [msg * price, pToken]],
        (k) => {
          k(null);
          transfer([[msg * price, pToken]]).to(s.manager);
          transfer(msg, token).to(this);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg,
            },
          ];
        },
      ];
    })
    // api: close
    //  - close contract
    .api_(a.close, () => {
      check(this == s.manager);
      return [
        (k) => {
          k(null);
          transfer([[s.tokenAmount, token]]).to(s.manager);
          return [
            {
              ...s,
              closed: true,
              tokenAmount: 0,
            },
          ];
        },
      ];
    })
    .timeout(false);
  commit();
  Relay.publish();
  transfer([
    [getUntrackedFunds(token), token],
    [getUntrackedFunds(pToken), pToken],
  ]).to(Relay);
  commit();
  exit();
};
// ----------------------------------------------
