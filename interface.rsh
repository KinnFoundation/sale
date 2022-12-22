"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale (token)
// Version: 0.1.2 - add safe buy
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import {
  State as SaleState,
  Params,
  api,
  view
} from "@KinnFoundation/sale#sale-v0.1.11r13:interface.rsh";

// CONSTANTS

const SERIAL_VER = 1;

// TYPES

export const State = Struct([
  ...Struct.fields(SaleState),
  ["pToken", Token],
  ["unclaimed", UInt],
]);

// FUN

const fClaim = Fun([], Null);
const fSafeBuy = Fun([UInt], Null);

// CONTRACT

export const Event = () => [Events({ appLaunch: [] })];
export const Participants = () => [
  Participant("Manager", {
    getParams: Fun([], Params),
  }),
  Participant("Relay", {}),
];
export const Views = () => [View(view(State))];
export const Api = () => [API({ ...api, safeBuy: fSafeBuy, claim: fClaim })];
export const App = (map) => {
  const [
    { amt, ttl, tok0: token, tok1: pToken },
    [addr, _],
    [Manager, Relay],
    [v],
    [a],
    [e],
  ] = map;

  Manager.only(() => {
    const { tokenAmount, tokenUnit, price, rate } = declassify(
      interact.getParams()
    );
  });
  Manager.publish(tokenAmount, tokenUnit, price, rate)
    .pay([amt + SERIAL_VER, [tokenAmount, token]])
    .check(() => {
      check(tokenAmount > 0, "tokenAmount must be greater than 0");
      check(price > 0, "price must be greater than 0");
      check(tokenUnit > 0, "tokenUnit must be greater than 0");
      check(rate >= 1, "rate must be greater than or equal to 1");
      check(rate <= 400, "rate must be less than or equal to 400");
    })
    .timeout(relativeTime(ttl), () => {
      Anybody.publish();
      commit();
      exit();
    });
  transfer(amt + SERIAL_VER).to(addr);
  e.appLaunch();

  const initialState = {
    manager: Manager,
    closed: false,
    token,
    tokenAmount,
    tokenUnit,
    tokenSupply: tokenAmount,
    price,
    pToken,
    rate,
    unclaimed: 0,
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
    .invariant(balance(pToken) == s.unclaimed, "payment token balance accurate")
    // BALANCE
    .invariant(balance() == 0, "balance accurate")
    .while(!s.closed)
    .paySpec([pToken, token])
    // api: touch
    .api_(a.touch, () => {
      check(this == s.manager, "only manager can touch");
      return [
        (k) => {
          k(null);
          transfer([
            getUntrackedFunds(),
            [getUntrackedFunds(pToken), pToken],
            [getUntrackedFunds(token), token],
          ]).to(s.manager);
          return [s];
        },
      ];
    })
    // api: deposit
    //  - deposit tokens
    .api_(a.deposit, (msg) => {
      check(this == s.manager, "only manager can deposit");
      check(msg > 0, "deposit must be greater than 0");
      return [
        [0, [0, pToken], [msg * s.tokenUnit, token]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount + msg * s.tokenUnit,
              tokenSupply: s.tokenSupply + msg * s.tokenUnit,
            },
          ];
        },
      ];
    })
    // api: withdraw
    //  - withdraw tokens
    .api_(a.withdraw, (msg) => {
      check(this == s.manager, "only manager can withdraw");
      check(msg > 0, "withdraw must be greater than 0");
      check(
        msg * s.tokenUnit <= s.tokenAmount,
        "withdraw must be less than or equal to token amount"
      );
      return [
        (k) => {
          k(null);
          transfer([[msg * s.tokenUnit, token]]).to(s.manager);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              tokenSupply: s.tokenSupply - msg * s.tokenUnit,
            },
          ];
        },
      ];
    })
    // api: update
    //  - update price
    .api_(a.updatePrice, (msg) => {
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
    // api: update
    // - update token unit
    .api_(a.updateTokenUnit, (msg) => {
      check(this === s.manager, "only manager can update");
      check(msg > 0, "tokenUnit must be greater than 0");
      check(
        s.tokenAmount % msg === 0,
        "tokenAmount must be divisible by tokenUnit"
      );
      return [
        (k) => {
          k(null);
          return [
            {
              ...s,
              tokenUnit: msg,
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
    //  - buy token (safe)
    .api_(a.safeBuy, (msg) => {
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [0, [msg * s.price, pToken], [0, token]],
        (k) => {
          k(null);
          const fee = (rate * msg * s.price) / 400; // > 0.25%
          transfer([[msg * s.price - fee, pToken]]).to(s.manager);
          transfer(msg * s.tokenUnit, token).to(this);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              unclaimed: s.unclaimed + fee,
            },
          ];
        },
      ];
    })
    // api: buy
    //  - buy token
    .api_(a.buy, (msg) => {
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [0, [msg * s.price, pToken], [0, token]],
        (k) => {
          k(null);
          const fee = (rate * msg * s.price) / 400; // > 0.25%
          transfer([[msg * s.price - fee, pToken]]).to(s.manager);
          transfer(msg * s.tokenUnit, token).to(this);
          transfer([[fee + s.unclaimed, pToken]]).to(addr);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              unclaimed: 0
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
    // api: claim
    //  - claim unclaimed funds before close
    .api_(a.claim, () => {
      return [
        (k) => {
          k(null);
          transfer([[s.unclaimed, pToken]]).to(addr);
          return [
            {
              ...s,
              unclaimed: 0,
            },
          ];
        },
      ];
    })
    .timeout(false);
  commit();
  Relay.publish();
  transfer([[s.unclaimed, pToken]]).to(addr);
  commit();
  exit();
};
// ----------------------------------------------
