%% Handle code related to args, guard and -> matching for case,
%% fn, receive and friends. try is handled in elixir_try.
-module(elixir_exp_clauses).
-export([match/3, clause/5, 'case'/3, 'receive'/3, 'try'/3, def/5]).
-import(elixir_errors, [compile_error/3, compile_error/4]).
-include("elixir.hrl").

match(Fun, Expr, #elixir_env{context=Context} = E) ->
  { EExpr, EE } = Fun(Expr, E#elixir_env{context=match}),
  { EExpr, EE#elixir_env{context=Context} }.

def(Fun, Args, Guards, Body, E) ->
  { EArgs, EA }   = match(Fun, Args, E),
  { EGuards, EG } = guard(Guards, EA#elixir_env{context=guard}),
  { EBody, EB }   = elixir_exp:expand(Body, EG#elixir_env{context=E#elixir_env.context}),
  { EArgs, EGuards, EBody, EB }.

clause(Meta, Kind, Fun, { '->', ClauseMeta, [_, _] } = Clause, E) when is_function(Fun, 3) ->
  clause(Meta, Kind, fun(X, Acc) -> Fun(ClauseMeta, X, Acc) end, Clause, E);
clause(_Meta, _Kind, Fun, { '->', Meta, [Left, Right] }, E) ->
  { ELeft, EL }  = head(Fun, Left, E),
  { ERight, ER } = elixir_exp:expand(Right, EL),
  { { '->', Meta, [ELeft, ERight] }, ER };
clause(Meta, Kind, _Fun, _, E) ->
  compile_error(Meta, E#elixir_env.file, "expected -> clauses in ~ts", [Kind]).

head(Fun, [{ 'when', Meta, [_,_|_] = All }], E) ->
  { Args, Guard } = elixir_utils:split_last(All),
  { EArgs, EA }   = match(Fun, Args, E),
  { EGuard, EG }  = guard(Guard, EA#elixir_env{context=guard}),
  { [{ 'when', Meta, EArgs ++ [EGuard] }], EG#elixir_env{context=E#elixir_env.context} };
head(Fun, Args, E) ->
  match(Fun, Args, E).

guard({ 'when', Meta, [Left, Right] }, E) ->
  { ELeft, EL }  = guard(Left, E),
  { ERight, ER } = guard(Right, EL),
  { { 'when', Meta, [ELeft, ERight] }, ER };
guard(Other, E) ->
  elixir_exp:expand(Other, E).

%% Case

'case'(Meta, [], E) ->
  compile_error(Meta, E#elixir_env.file, "missing do keyword in case");
'case'(Meta, KV, E) when not is_list(KV) ->
  compile_error(Meta, E#elixir_env.file, "invalid arguments for case");
'case'(Meta, KV, E) ->
  { EClauses, { _, EV } } =
    lists:mapfoldl(fun(X, Acc) -> do_case(Meta, X, Acc) end, { E, E }, KV),
  { EClauses, elixir_env:mergevc(EV, E) }.

do_case(Meta, { 'do', _ } = Do, Acc) ->
  expand_with_vars(Meta, 'case', expand_arg(Meta, 'case', 'do'), Do, Acc);
do_case(Meta, { Key, _ }, { E, _ }) ->
  compile_error(Meta, E#elixir_env.file, "unexpected keyword ~ts in case", [Key]).

%% Receive

'receive'(Meta, [], E) ->
  compile_error(Meta, E#elixir_env.file, "missing do or after keyword in receive");
'receive'(Meta, KV, E) when not is_list(KV) ->
  compile_error(Meta, E#elixir_env.file, "invalid arguments for receive");
'receive'(Meta, KV, E) ->
  { EClauses, { _, EV } } =
    lists:mapfoldl(fun(X, Acc) -> do_receive(Meta, X, Acc) end, { E, E }, KV),
  { EClauses, EV }.

do_receive(_Meta, { 'do', nil } = Do, Acc) ->
  { Do, Acc };
do_receive(Meta, { 'do', _ } = Do, Acc) ->
  expand_with_vars(Meta, 'receive', expand_arg(Meta, 'receive', 'do'), Do, Acc);
do_receive(_Meta, { 'after', [{ '->', Meta, [[Left], Right] }] }, { Acc1, Acc2 }) ->
  { ELeft, EL }  = elixir_exp:expand(Left, Acc1),
  { ERight, ER } = elixir_exp:expand(Right, EL),
  EClause = { 'after', [{ '->', Meta, [[ELeft], ERight] }] },
  { EClause, { elixir_env:mergec(Acc1, ER), elixir_env:mergev(Acc2, ER) } };
do_receive(Meta, { 'after', _ }, { E, _ }) ->
  compile_error(Meta, E#elixir_env.file, "expected a single -> clause for after in receive");
do_receive(Meta, { Key, _ }, { E, _ }) ->
  compile_error(Meta, E#elixir_env.file, "unexpected keyword ~ts in receive", [Key]).

%% Try

'try'(Meta, [], E) ->
  compile_error(Meta, E#elixir_env.file, "missing do keywords in try");
'try'(Meta, KV, E) when not is_list(KV) ->
  elixir_errors:compile_error(Meta, E#elixir_env.file, "invalid arguments for try");
'try'(Meta, KV, E) ->
  lists:mapfoldl(fun(X, Acc) -> do_try(Meta, X, Acc) end, E, KV).

do_try(_Meta, { 'do', Expr }, E) ->
  { EExpr, EE } = elixir_exp:expand(Expr, E),
  { { 'do', EExpr }, elixir_env:mergec(E, EE) };
do_try(_Meta, { 'after', Expr }, E) ->
  { EExpr, EE } = elixir_exp:expand(Expr, E),
  { { 'after', EExpr }, elixir_env:mergec(E, EE) };
do_try(Meta, { 'else', _ } = Else, E) ->
  expand_without_vars(Meta, 'try', expand_arg(Meta, 'try', 'else'), Else, E);
do_try(Meta, { 'catch', _ } = Catch, E) ->
  expand_without_vars(Meta, 'try', fun elixir_exp:expand_many/2, Catch, E);
do_try(Meta, { 'rescue', _ } = Rescue, E) ->
  expand_without_vars(Meta, 'try', fun expand_rescue/3, Rescue, E);
do_try(Meta, { Key, _ }, E) ->
  compile_error(Meta, E#elixir_env.file, "unexpected keyword ~ts in try", [Key]).

expand_rescue(Meta, [Arg], E) ->
  case expand_rescue(Arg, E) of
    { EArg, EA } ->
      { [EArg], EA };
    false ->
      compile_error(Meta, E#elixir_env.file, "invalid rescue clause. The clause should "
        "match on an alias, a variable or be in the `var in [alias]` format")
  end;
expand_rescue(Meta, _, E) ->
  compile_error(Meta, E#elixir_env.file, "expected one arg for rescue clauses (->) in try").

%% rescue var => var in _
expand_rescue({ Name, _, Atom } = Var, E) when is_atom(Name), is_atom(Atom) ->
  expand_rescue({ in, [], [Var, { '_', [], E#elixir_env.module }] }, E);

%% rescue var in [Exprs]
expand_rescue({ in, Meta, [Left, Right] }, E) ->
  { ERight, ER } = elixir_exp:expand(Right, E#elixir_env{context=nil}),
  { ELeft, EL }  = elixir_exp:expand(Left, ER#elixir_env{context=match}),

  case ELeft of
    { Name, _, Atom } when is_atom(Name), is_atom(Atom) ->
      case normalize_rescue(ERight) of
        false -> false;
        Other -> { { in, Meta, [ELeft, Other] }, EL }
      end;
    _ ->
      false
  end;

%% rescue Error => _ in [Error]
expand_rescue(Arg, E) ->
  expand_rescue({ in, [], [{ '_', [], E#elixir_env.module }, Arg] }, E).

normalize_rescue({ '_', _, Atom } = N) when is_atom(Atom) -> N;
normalize_rescue(Atom) when is_atom(Atom) -> [Atom];
normalize_rescue(Other) ->
  is_list(Other)
    andalso lists:all(fun is_var_or_atom/1, Other)
    andalso Other.

is_var_or_atom({ Name, _, Atom }) when is_atom(Name), is_atom(Atom) -> true;
is_var_or_atom(Atom) when is_atom(Atom) -> true;
is_var_or_atom(_) -> false.

%% Expansion helpers

%% Returns a function that expands arguments
%% considering we have at maximum one entry.
expand_arg(Meta, Kind, Key) ->
  fun
    ([Arg], E) ->
      { EArg, EA } = elixir_exp:expand(Arg, E),
      { [EArg], EA };
    (_, E) ->
      compile_error(Meta, E#elixir_env.file, "expected one arg for ~ts clauses (->) in ~ts", [Key, Kind])
  end.

%% Expands all -> pairs in a given key keeping the overall vars.
expand_with_vars(Meta, Kind, Fun, { Key, Clauses }, Acc) when is_list(Clauses) ->
  Transformer = fun(Clause, { Acc1, Acc2 }) ->
    { EClause, EC } = clause(Meta, Kind, Fun, Clause, Acc1),
    { EClause, { elixir_env:mergec(Acc1, EC), elixir_env:mergev(Acc2, EC) } }
  end,
  { EClauses, EAcc } = lists:mapfoldl(Transformer, Acc, Clauses),
  { { Key, EClauses }, EAcc };
expand_with_vars(Meta, Kind, _Fun, { Key, _ }, { E, _ }) ->
  compile_error(Meta, E#elixir_env.file, "expected -> clauses for ~ts in ~ts", [Key, Kind]).

%% Expands all -> pairs in a given key but do not keep the overall vars.
expand_without_vars(Meta, Kind, Fun, { Key, Clauses }, Acc) when is_list(Clauses) ->
  Transformer = fun(Clause, E) ->
    { EClause, EC } = clause(Meta, Kind, Fun, Clause, E),
    { EClause, elixir_env:mergec(E, EC) }
  end,
  { EClauses, EAcc } = lists:mapfoldl(Transformer, Acc, Clauses),
  { { Key, EClauses }, EAcc };
expand_without_vars(Meta, Kind, _Fun, { Key, _ }, E) ->
  compile_error(Meta, E#elixir_env.file, "expected -> clauses for ~ts in ~ts", [Key, Kind]).