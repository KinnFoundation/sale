"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale
// Version: 0.4.0 - update buy api
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import {
  State as BaseState,
  Params as BaseParams,
  TokenState,
  view,
  baseState,
  baseEvents,
  MContract,
  MToken,
  max,
  min
} from "@KinnFoundation/base#base-v0.1.11r16:interface.rsh";

import { rPInfo } from "@ZestBloom/humble#humble-v0.1.11r2:interface.rsh";

// CONSTANTS

const SERIAL_VER = 0;

// TYPES

export const SaleState = Struct([
  ["tokenUnit", UInt], // token unit
  ["tokenSupply", UInt], // token supply
  ["price", UInt], // price
  ["rate", UInt], // rate
]);

export const RemoteState = Struct([
  ["remoteCtc", Contract],
  ["remoteToken", Token],
]);

export const SafeState = Struct([["safeAmount", UInt]]);

export const State = Struct([
  ...Struct.fields(BaseState),
  ...Struct.fields(TokenState),
  ...Struct.fields(SaleState),
  ...Struct.fields(RemoteState),
  ...Struct.fields(SafeState),
]);

export const SaleParams = Object({
  tokenAmount: UInt, // token amount
  tokenUnit: UInt, // token unit
  price: UInt, // price per token
  rate: UInt, // rate per token
});

export const RemoteParams = Object({
  remoteCtc: Contract,
});

export const Params = Object({
  ...Object.fields(BaseParams),
  ...Object.fields(SaleParams),
  ...Object.fields(RemoteParams),
});

// FUN

const fBuy = Fun([Address, UInt, UInt], Null); // buy
const fBuyRemote = Fun([Address, UInt, UInt], Null); // buy
const fBuyRemoteToken = Fun([Address, UInt, UInt], Null); // buy
const fSafeBuyRemoteToken = Fun([Address, UInt, UInt], Null); // buy
const fClose = Fun([Address], Null); // manager only
const fGrant = Fun([Address], Null); // manager only
const fUpdatePrice = Fun([UInt], Null); // manager only
const fUpdateTokenUnit = Fun([UInt], Null); // manager only
const fUpdateRemoteCtc = Fun([Contract], Null); // manager only
const fDeposit = Fun([UInt], Null); // manager only
const fWithdraw = Fun([Address, UInt], Null); // manager only
const fTouch = Fun([Address], Null); // manager only

// API

export const api = {
  buy: fBuy,
  buyRemote: fBuyRemote,
  buyRemoteToken: fBuyRemoteToken,
  safeBuyRemoteToken: fSafeBuyRemoteToken,
  close: fClose,
  grant: fGrant,
  updatePrice: fUpdatePrice,
  updateTokenUnit: fUpdateTokenUnit,
  updateRemoteCtc: fUpdateRemoteCtc,
  deposit: fDeposit,
  withdraw: fWithdraw,
  touch: fTouch,
};

// CONTRACT

export const Event = () => [Events({ ...baseEvents })];
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
    { amt, ttl, tok0: token, tok1: pToken },
    [addr, _],
    [Manager, Relay],
    [v],
    [a],
    [e],
  ] = map;

  Manager.only(() => {
    const { tokenAmount, tokenUnit, price, rate, remoteCtc } = declassify(
      interact.getParams()
    );
  });
  Manager.publish(tokenAmount, tokenUnit, price, rate, remoteCtc)
    .pay([amt + SERIAL_VER, [tokenAmount, token]])
    .check(() => {
      check(tokenAmount > 0, "tokenAmount must be greater than 0");
      check(price > 0, "price must be greater than 0");
      check(tokenUnit > 0, "tokenUnit must be greater than 0");
      check(
        tokenAmount % tokenUnit === 0,
        "tokenAmount must be divisible by tokenUnit"
      );
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
    ...baseState(Manager),
    token,
    tokenAmount,
    tokenUnit,
    tokenSupply: tokenAmount,
    price,
    rate,
    remoteCtc,
    remoteToken: pToken,
    safeAmount: 0,
  };

  const [initialMCtc, initialMToken] = ((thisCtc) => {
    if (thisCtc != remoteCtc) {
      return [MContract.Some(thisCtc), MToken.Some(token)];
    } else {
      return [MContract.None(), MToken.None()];
    }
  })(getContract());

  const [s, mctc, rtok] = parallelReduce([
    initialState,
    initialMCtc,
    initialMToken,
  ])
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
    // P-TOKEN BALANCE
    .invariant(
      balance(pToken) == s.safeAmount,
      "payment token balance accurate"
    )
    // BALANCE
    .invariant(balance() == 0, "balance accurate")
    .while(!s.closed)
    .paySpec([token, pToken])
    // api: touch
    .api_(a.touch, (recv) => {
      check(this == s.manager, "only manager can touch");
      return [
        (k) => {
          k(null);
          transfer([
            getUntrackedFunds(),
            [getUntrackedFunds(token), token],
            [getUntrackedFunds(pToken), pToken],
          ]).to(recv);
          return [s, mctc, rtok];
        },
      ];
    })
    // api: deposit
    //  - deposit tokens
    .api_(a.deposit, (msg) => {
      check(this == s.manager, "only manager can deposit");
      check(msg > 0, "deposit must be greater than 0");
      return [
        [0, [msg * s.tokenUnit, token], [0, pToken]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount + msg * s.tokenUnit,
              tokenSupply: s.tokenSupply + msg * s.tokenUnit,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: withdraw
    //  - withdraw tokens
    .api_(a.withdraw, (recv, msg) => {
      check(this == s.manager, "only manager can withdraw");
      check(msg > 0, "withdraw must be greater than 0");
      check(
        msg * s.tokenUnit <= s.tokenAmount,
        "withdraw must be less than or equal to token amount"
      );
      return [
        (k) => {
          k(null);
          transfer([[msg * s.tokenUnit, token]]).to(recv);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              tokenSupply: s.tokenSupply - msg * s.tokenUnit,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: update
    //  - update price
    .api_(a.updatePrice, (msg) => {
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
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: updateTokenUnit
    //  - update token unit
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
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: updateRemoteCtc
    //  - update remote contract
    // .  + remove remote by setting remote to self
    // .  + try remote else fail with state unchanged
    .api_(a.updateRemoteCtc, (msg) => {
      check(this === s.manager, "only manager can update remote contract");
      return [
        (k) => {
          k(null);
          if (msg != getContract()) {
            const info = rPInfo(msg);
            const { tokB } = info;
            return [
              {
                ...s,
                remoteCtc: msg,
                remoteToken: tokB,
              },
              MContract.Some(msg),
              MToken.Some(tokB),
            ];
          } else {
            return [
              { ...s, remoteCtc: getContract(), remoteToken: pToken },
              MContract.None(),
              MToken.None(),
            ];
          }
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
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: buy
    //  - buy token (ALGO)
    .api_(a.buy, (recv, inTok, outCap) => {
      check(isNone(mctc), "remote contract set");
      check(
        (inTok / s.price) * s.tokenUnit <= s.tokenAmount,
        "not enough tokens"
      );
      return [
        [inTok, [0, token], [0, pToken]],
        (k) => {
          k(null);
          const fee = ((inTok / s.price) * s.price * s.rate) / 400; // > 0.25%
          const avail = inTok - fee;

          const inCap = avail / s.price;

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * s.price; // change to return to sender for exchange
            transfer(avail - change).to(s.manager);
            transfer([change, [cap * s.tokenUnit, token]]).to(recv);
            transfer(fee).to(addr);
            return [
              {
                ...s,
                tokenAmount: s.tokenAmount - cap * s.tokenUnit,
              },
              mctc,
              rtok,
            ];
          } else {
            transfer(inTok).to(recv);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: buy (remote)
    //  - buy token (ALGO)
    .api_(a.buyRemote, (recv, inTok, outCap) => {
      check(isSome(mctc), "remote contract not set");
      check(s.tokenAmount > 0, "No tokens left");
      return [
        [inTok, [0, token], [0, pToken]],
        (k) => {
          k(null);

          const fee = (inTok * s.rate) / 400; // > 0.25%

          const avail = inTok - fee;

          const pInfo = rPInfo(s.remoteCtc);
          const poolBals = pInfo.poolBals;
          const { A, B } = poolBals;

          const conv = muldiv(s.price, max(A, 1), max(B, 1)); // net to token conversion amount

          const precision = UInt.max;

          const inCap = UInt(
            (UInt256(avail) * UInt256(precision)) /
              UInt256(conv) /
              UInt256(precision),
            false
          );

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * conv; // change to return to sender for exchange
            transfer([avail - change]).to(s.manager); // payment to manager
            transfer([[cap * s.tokenUnit, token]]).to(recv); // token exchange
            transfer([change]).to(recv); // change to signer
            transfer([fee]).to(addr); // fee to launcher
            return [
              {
                ...s,
                tokenAmount: s.tokenAmount - cap * s.tokenUnit,
              },
              mctc,
              rtok,
            ];
          } else {
            transfer([inTok]).to(this);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: buy (remote)
    //  - buy (TOKEN)
    .api_(a.buyRemoteToken, (recv, inTok, outCap) => {
      check(isSome(mctc), "remote contract not set");
      check(isSome(rtok), "remote token not set");
      check(
        (inTok / s.price) * s.tokenUnit <= s.tokenAmount,
        "not enough tokens"
      );
      check(
        s.remoteToken == pToken,
        "remote token does not match payment token"
      );
      return [
        [0, [0, token], [inTok, pToken]],
        (k) => {
          k(null);

          const fee = (inTok * s.rate) / 400; // > 0.25%

          const avail = inTok - fee;

          const inCap = avail / s.price;

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * s.price; // change to return to sender for exchange
            transfer([[avail - change, pToken]]).to(s.manager); // payment to manager
            transfer([[cap * s.tokenUnit, token]]).to(recv); // token exchange
            transfer([[change, pToken]]).to(recv); // change to signer
            transfer([[fee + s.safeAmount, pToken]]).to(addr); // fee to launcher
            return [
              {
                ...s,
                tokenAmount: s.tokenAmount - cap * s.tokenUnit,
                safeAmount: 0,
              },
              mctc,
              rtok,
            ];
          } else {
            transfer([[inTok, pToken]]).to(this);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: buy (remote)
    //  - safe buy token (TOKEN)
    .api_(a.safeBuyRemoteToken, (recv, inTok, outCap) => {
      check(isSome(mctc), "remote contract not set");
      check(isSome(rtok), "remote token not set");
      check(
        (inTok / s.price) * s.tokenUnit <= s.tokenAmount,
        "not enough tokens"
      );
      check(
        s.remoteToken == pToken,
        "remote token does not match payment token"
      );
      return [
        [0, [0, token], [inTok, pToken]],
        (k) => {
          k(null);

          const fee = (inTok * s.rate) / 400; // > 0.25%

          const avail = inTok - fee;

          const inCap = avail / s.price;

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * s.price; // change to return to sender for exchange
            transfer([[avail - change, pToken]]).to(s.manager); // payment to manager
            transfer([[cap * s.tokenUnit, token]]).to(recv); // token exchange
            transfer([[change, pToken]]).to(recv); // change to signer
            return [
              {
                ...s,
                tokenAmount: s.tokenAmount - cap * s.tokenUnit,
                safeAmount: s.safeAmount + fee,
              },
              mctc,
              rtok,
            ];
          } else {
            transfer([[inTok, pToken]]).to(this);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: close
    //  - close contract
    .api_(a.close, (recv) => {
      check(this == s.manager, "only manager can close");
      return [
        (k) => {
          k(null);
          transfer([[s.tokenAmount, token]]).to(recv);
          return [
            {
              ...s,
              closed: true,
              tokenAmount: 0,
              tokenSupply: 0,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    .timeout(false);
  e.appClose();
  commit();
  Relay.publish();
  transfer([[s.safeAmount, pToken]]).to(addr);
  commit();
  exit();
};
// ----------------------------------------------
