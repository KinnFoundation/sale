"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale
// Version: 0.2.0 - add remote buy
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
  max,
  min
} from "@KinnFoundation/base#base-v0.1.11r16:interface.rsh";

import { rPInfo } from "@ZestBloom/humble#humble-v0.1.11r1:interface.rsh";

// CONSTANTS

const SERIAL_VER = 0;

// TYPES

export const SaleState = Struct([
  ["tokenUnit", UInt], // token unit
  ["tokenSupply", UInt], // token supply
  ["price", UInt], // price
  ["rate", UInt], // rate
]);

export const RemoteState = Struct([["remoteCtc", Contract]]);

export const State = Struct([
  ...Struct.fields(BaseState),
  ...Struct.fields(TokenState),
  ...Struct.fields(SaleState),
  ...Struct.fields(RemoteState),
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

const fBuy = Fun([Address, UInt], Null);
const fBuyRemote = Fun([Address, UInt, UInt], Null);
const fClose = Fun([Address], Null); // manager only
const fGrant = Fun([Address], Null); // manager only
const fUpdatePrice = Fun([UInt], Null); // manager only
const fUpdateTokenUnit = Fun([UInt], Null); // manager only
const fUpdateRemoteCtc = Fun([Contract], Null); // manager only
const fDeposit = Fun([UInt], Null); // manager only
const fWithdraw = Fun([Address, UInt], Null); // manager only
const fTouch = Fun([Address], Null); // manager only

// REMOTE FUN

export const rBuy = (ctc, addr, amt) => {
  const r = remote(ctc, { buy: fBuy });
  return r.buy(addr, amt);
};

export const rBuyRemote = (ctc, addr, amt, cap) => {
  const r = remote(ctc, { buyRemote: fBuyRemote });
  return r.buyRemote(addr, amt, cap);
}

// API

export const api = {
  buy: fBuy,
  buyRemote: fBuyRemote,
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
    { amt, ttl, tok0: token },
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
    remoteCtc
  };

  const [s, mctc] = parallelReduce([initialState, MContract.Some(remoteCtc)])
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
    .paySpec([token])
    // api: touch
    .api_(a.touch, (recv) => {
      check(this == s.manager, "only manager can touch");
      return [
        (k) => {
          k(null);
          transfer([getUntrackedFunds(), [getUntrackedFunds(token), token]]).to(
            recv
          );
          return [s, mctc];
        },
      ];
    })
    // api: deposit
    //  - deposit tokens
    .api_(a.deposit, (msg) => {
      check(this == s.manager, "only manager can deposit");
      check(msg > 0, "deposit must be greater than 0");
      return [
        [0, [msg * s.tokenUnit, token]],
        (k) => {
          k(null);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount + msg * s.tokenUnit,
              tokenSupply: s.tokenSupply + msg * s.tokenUnit,
            },
            mctc,
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
          ];
        },
      ];
    })
    // api: updateRemoteCtc
    //  - update remote contract
    .api_(a.updateRemoteCtc, (msg) => {
      check(this === s.manager, "only manager can update remote contract");
      return [
        (k) => {
          k(null);
          if(msg != getContract()) {
            return [s, MContract.Some(msg)];
          } else {
            return [s, MContract.None()];
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
          ];
        },
      ];
    })
    // api: buy
    //  - buy token
    .api_(a.buy, (recv, msg) => {
      check(isNone(mctc), "remote contract set");
      check(msg * s.tokenUnit <= s.tokenAmount, "not enough tokens");
      return [
        [msg * s.price, [0, token]],
        (k) => {
          k(null);
          const fee = (s.rate * msg * s.price) / 400; // > 0.25%
          transfer(msg * s.price - fee).to(s.manager);
          transfer(fee).to(addr);
          transfer(msg * s.tokenUnit, token).to(recv);
          return [
            {
              ...s,
              tokenAmount: s.tokenAmount - msg * s.tokenUnit,
            },
            mctc,
          ];
        },
      ];
    })
        // api: buy (remote)
    //  - buy token (remote)
    .api_(a.buyRemote, (recv, inTok, outCap) => {
    check(isSome(mctc), "remote contract not set");
      check(s.tokenAmount > 0, "No tokens left");
      return [
        [inTok, [0, token]],
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
              mctc
            ];
          } else {
            transfer([inTok]).to(this);
            return [s, mctc];
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
          ];
        },
      ];
    })
    .timeout(false);
  e.appClose();
  commit();
  Relay.publish();
  commit();
  exit();
};
// ----------------------------------------------
