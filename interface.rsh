"reach 0.1";
"use strict";
// -----------------------------------------------
// Name: KINN Token Sale
// Version: 0.0.3 - export api and view
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

// TYPES

export const State = Struct([
  ["manager", Address],
  ["token", Token],
  ["tokenAmount", UInt],
  ["closed", Bool],
  ["price", UInt],
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

// API

export const api = {
  buy,
  close: Fun([], Null),
  grant: Fun([Address], Null),
  update: Fun([UInt], Null),
};

// VIEW

export const view = {
  state: State,
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
export const Views = () => [View(view)];
export const Api = () => [API(api)];
export const App = (map) => {
  const [{ amt, ttl, tok0: token }, [addr, _], [Manager, Relay], [v], [a], _] =
    map;

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
      transfer(getUntrackedFunds(token), token).to(addr);
      commit();
      exit();
    });
  transfer(amt).to(addr);
  Manager.interact.signal();

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
  transfer([[getUntrackedFunds(token), token]]).to(Relay);
  commit();
  exit();
};
// ----------------------------------------------
