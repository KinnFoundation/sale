"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale
// Version: 0.5.3 - cleanup, add mode to view
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

export const MODE_NET_ONLY = 0;
export const MODE_TOK_ONLY = 1;
export const MODE_NET_TOK = 2;

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

export const ModeState = Struct([
  ["mode", UInt], // 0: net, 1: tok, 2: net+tok
]);

export const SafeState = Struct([["safeAmount", UInt]]);

export const State = Struct([
  ...Struct.fields(BaseState),
  ...Struct.fields(TokenState),
  ...Struct.fields(SaleState),
  ...Struct.fields(RemoteState),
  ...Struct.fields(ModeState),
  ...Struct.fields(SafeState),
]);

export const SaleParams = Object({
  tokenAmount: UInt, // token amount
  tokenUnit: UInt, // token unit
  price: UInt, // price per token
  rate: UInt, // rate per token
});

export const ModeParams = Object({
  mode: UInt, // 0: net, 1: tok, 2: net+tok
});

export const RemoteParams = Object({
  remoteCtc: Contract,
});

export const Params = Object({
  ...Object.fields(BaseParams),
  ...Object.fields(SaleParams),
  ...Object.fields(ModeParams),
  ...Object.fields(RemoteParams),
});

// FUN

const fBuy = Fun([Address, UInt, UInt], Null); // buy
const fBuySelf = Fun([UInt], Null); // buy
const fBuyToken = Fun([Address, UInt, UInt], Null); // buy
const fSafeBuyToken = Fun([Address, UInt, UInt], Null); // buy
const fBuyTokenSelf = Fun([UInt], Null); // buy
const fSafeBuyTokenSelf = Fun([UInt], Null); // buy
const fBuyRemote = Fun([Address, UInt, UInt], Null); // buy
const fBuyRemoteToken = Fun([Address, UInt, UInt], Null); // buy
const fSafeBuyRemoteToken = Fun([Address, UInt, UInt], Null); // buy
const fClose = Fun([Address], Null); // manager only
const fGrant = Fun([Address], Null); // manager only
const fUpdate = Fun([UInt, UInt, Contract, UInt], Null); // manager only
const fDeposit = Fun([UInt], Null); // manager only
const fWithdraw = Fun([Address, UInt], Null); // manager only

// API

export const api = {
  buy: fBuy,
  buySelf: fBuySelf,
  buyToken: fBuyToken,
  safeBuyToken: fSafeBuyToken,
  buyTokenSelf: fBuyTokenSelf,
  safeBuyTokenSelf: fSafeBuyTokenSelf,
  buyRemote: fBuyRemote,
  buyRemoteToken: fBuyRemoteToken,
  safeBuyRemoteToken: fSafeBuyRemoteToken,
  close: fClose,
  grant: fGrant,
  update: fUpdate,
  deposit: fDeposit,
  withdraw: fWithdraw,
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
    const { tokenAmount, tokenUnit, price, rate, remoteCtc, mode } = declassify(
      interact.getParams()
    );
  });
  Manager.publish(tokenAmount, tokenUnit, price, rate, remoteCtc, mode)
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
      check(mode >= 0, "mode must be greater than or equal to 0");
      check(mode <= 2, "mode must be less than or equal to 2");
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
    mode,
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
    .api_(a.update, (aPrice, aTokenUnit, aRemoteCtc, aMode) => {
      check(this === s.manager, "only manager can update");
      check(aPrice > 0, "price must be greater than 0");
      check(aTokenUnit > 0, "tokenUnit must be greater than 0");
      check(
        s.tokenAmount % aTokenUnit === 0,
        "tokenAmount must be divisible by tokenUnit"
      );
      check(mode >= 0, "mode must be greater than or equal to 0");
      check(mode <= 2, "mode must be less than or equal to 2");
      return [
        (k) => {
          k(null);
          if (aRemoteCtc != getContract()) {
            const info = rPInfo(aRemoteCtc);
            const { tokB } = info;
            return [
              {
                ...s,
                remoteCtc: aRemoteCtc,
                remoteToken: tokB,
                price: aPrice,
                tokenUnit: aTokenUnit,
                mode: aMode,
              },
              MContract.Some(remoteCtc),
              MToken.Some(tokB),
            ];
          } else {
            return [
              {
                ...s,
                remoteCtc: getContract(),
                remoteToken: pToken,
                price: aPrice,
                tokenUnit: aTokenUnit,
                mode: aMode,
              },
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
      check(mode === MODE_NET_ONLY, "only can buy in net mode");
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
    // api: buy
    //  - buy token (ALGO)
    .api_(a.buySelf, (msg) => {
      check(mode === MODE_NET_ONLY, "only can buy in net mode");
      check(isNone(mctc), "remote contract set");
      check(msg > 0, "must buy at least 1 token");
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [msg * s.price, [0, token], [0, pToken]],
        (k) => {
          k(null);
          const fee = (s.rate * msg * s.price) / 400; // > 0.25%
          const avail = msg * s.price - fee;
          transfer(avail).to(s.manager);
          transfer(fee).to(addr);
          transfer([[msg * s.tokenUnit, token]]).to(this);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: buy token
    //  - buy token
    .api_(a.buyToken, (recv, inTok, outCap) => {
      check(mode === MODE_TOK_ONLY, "only can buy in net mode");
      check(isNone(mctc), "remote contract set");
      check(
        (inTok / s.price) * s.tokenUnit <= s.tokenAmount,
        "not enough tokens"
      );
      return [
        [0, [0, token], [inTok, pToken]],
        (k) => {
          k(null);
          const fee = ((inTok / s.price) * s.price * s.rate) / 400; // > 0.25%
          const avail = inTok - fee;

          const inCap = avail / s.price;

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * s.price; // change to return to sender for exchange
            transfer([[avail - change, pToken]]).to(s.manager);
            transfer([
              [change, pToken],
              [cap * s.tokenUnit, token],
            ]).to(recv);
            transfer([[fee + s.safeAmount, pToken]]).to(addr);
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
            transfer([[inTok, pToken]]).to(recv);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: buy token
    //  - buy token
    .api_(a.safeBuyToken, (recv, inTok, outCap) => {
      check(mode === MODE_TOK_ONLY, "only can buy in net mode");
      check(isNone(mctc), "remote contract set");
      check(
        (inTok / s.price) * s.tokenUnit <= s.tokenAmount,
        "not enough tokens"
      );
      return [
        [0, [0, token], [inTok, pToken]],
        (k) => {
          k(null);
          const fee = ((inTok / s.price) * s.price * s.rate) / 400; // > 0.25%
          const avail = inTok - fee;

          const inCap = avail / s.price;

          const cap = min(inCap, outCap);

          if (cap * s.tokenUnit <= s.tokenAmount && cap > 0) {
            const change = avail - cap * s.price; // change to return to sender for exchange
            transfer([[avail - change, pToken]]).to(s.manager);
            transfer([
              [change, pToken],
              [cap * s.tokenUnit, token],
            ]).to(recv);
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
            transfer([[inTok, pToken]]).to(recv);
            return [s, mctc, rtok];
          }
        },
      ];
    })
    // api: buy token
    //  - buy token
    .api_(a.buyTokenSelf, (msg) => {
      check(mode === MODE_TOK_ONLY, "only can buy in tok mode");
      check(isNone(mctc), "remote contract set");
      check(msg > 0, "must buy at least 1 token");
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [0, [0, token], [msg * s.price, pToken]],
        (k) => {
          k(null);
          const fee = (s.rate * msg * s.price) / 400; // > 0.25%
          const avail = msg * s.price - fee;
          transfer([[avail, pToken]]).to(s.manager);
          transfer([[msg * s.tokenUnit, token]]).to(this);
          transfer([[fee + s.safeAmount, pToken]]).to(addr);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              safeAmount: 0,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: buy token
    //  - buy token
    .api_(a.safeBuyTokenSelf, (msg) => {
      check(mode === MODE_TOK_ONLY, "only can buy in tok mode");
      check(isNone(mctc), "remote contract set");
      check(msg > 0, "must buy at least 1 token");
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [0, [0, token], [msg * s.price, pToken]],
        (k) => {
          k(null);
          const fee = (s.rate * msg * s.price) / 400; // > 0.25%
          const avail = msg * s.price - fee;
          transfer([[avail, pToken]]).to(s.manager);
          transfer([[msg * s.tokenUnit, token]]).to(this);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
              safeAmount: s.safeAmount + fee,
            },
            mctc,
            rtok,
          ];
        },
      ];
    })
    // api: buy (remote)
    //  - buy token (ALGO)
    .api_(a.buyRemote, (recv, inTok, outCap) => {
      check(mode === MODE_NET_TOK, "only can buy in net+tok mode");
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
      check(mode === MODE_NET_TOK, "only can buy in net+tok mode");
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
      check(mode === MODE_NET_TOK, "only can buy in net+tok mode");
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
