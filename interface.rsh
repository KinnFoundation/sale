"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale
// Version: 0.0.10 - add update manager check
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import {
  State as BaseState,
  Params as BaseParams
} from "@KinnFoundation/base#base-v0.1.11r0:interface.rsh";

// TYPES

export const SaleState = Struct([
  ["token", Token], // token
  ["tokenAmount", UInt], // token amount
  ["price", UInt], // price
])

export const State = Struct([
  ...Struct.fields(BaseState),
  ...Struct.fields(SaleState),
]);


export const SaleParams = Object({
  tokenAmount: UInt, // token amount
  price: UInt, // price per token
})

export const Params = Object({
  ...Object.fields(BaseParams),
  ...Object.fields(SaleParams),
});

// FUN

const fState = (State) => Fun([], State);
const fBuy = Fun([UInt], Null);
const fClose = Fun([], Null);
const fGrant = Fun([Address], Null);
const fUpdate = Fun([UInt], Null);

// REMOTE FUN

export const rState = (ctc, State) => {
  const r = remote(ctc, { state: fState(State) });
  return r.state();
};

export const rBuy = (ctc) => {
  const r = remote(ctc, { buy: fBuy });
  return r.buy();
};

// API

export const api = {
  buy: fBuy,
  close: fClose,
  grant: fGrant,
  update: fUpdate,
};

// VIEW

export const view = (state) => {
  return {
    state,
  };
};

// CONTRACT

export const Event = () => [Events({ appLaunch: [] })];
export const Participants = () => [
  Participant("Manager", {
    getParams: Fun([], Params),
  }),
  Participant("Relay", {}),
];
export const Views = () => [View(view(State))];
export const Api = () => [API(api)];
export const App = (map) => {
  const [
    { amt, ttl, tok0: token },
    [addr, _],
    [Manager, Relay],
    [v],
    [a],
    [e],
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
      Anybody.publish();
      commit();
      exit();
    });
  transfer(amt).to(addr);
  e.appLaunch();

  const initialState = {
    manager: Manager,
    token,
    tokenAmount,
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
    // BALANCE
    .invariant(balance() == 0, "balance accurate")
    .while(!s.closed)
    // api: update
    //  - update price
    .api_(a.update, (msg) => {
      check(this === s.manager, "only manager can update");
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
      check(this === s.manager, "only manager can grant");
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
        msg * price,
        (k) => {
          k(null);
          transfer(msg * price).to(s.manager);
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
      check(this == s.manager, "only manager can close");
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
  commit();
  exit();
};
// ----------------------------------------------
