%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU Lesser General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU Lesser General Public License for more details.
%%%
%%% You should have received a copy of the GNU Lesser General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% This module contains the utility functions for edts rte
%% Record related stuff are shamelessly copied from shell.erl

%%%_* Module declaration =======================================================
-module(edts_rte_util).

%%%_* Exports =================================================================
-export([ convert_list_to_term/1
        , expand_records/2
        , extract_fun_clauses_line_num/1
        , get_function_abscode/3
        , get_module_sorted_fun_info/1
        , is_tail_call/3
        , read_and_add_records/2
        , record_table_name/0
        , traverse_clause_struct/2
        , var_to_val_in_fun/3
        ]).

%%%_* Includes =================================================================
-include_lib("kernel/include/file.hrl").

-record(clause_struct, { line       = undefined :: integer()
                       , sub_clause = undefined :: #clause_struct{}
                       , touched    = false     :: boolean()
                       }).

-type clause_struct() :: #clause_struct{}.

%%%_* API ======================================================================
convert_list_to_term(Arguments) ->
  edts_rte_app:debug("args:~p~n", [Arguments]),
  %% N.B. this is very hackish. added a '.' because
  %%      erl_scan:string/1 requires full expression with dot
  {ok, Tokens,__Endline} = erl_scan:string(Arguments++"."),
  edts_rte_app:debug("tokens:~p~n", [Tokens]),
  {ok, AbsForm0}         = erl_parse:parse_exprs(Tokens),
  AbsForm                = replace_var_with_val_in_expr(AbsForm0, [], [], true),
  edts_rte_app:debug("absf:~p~n", [AbsForm0]),
  edts_rte_app:debug("absf:~p~n", [AbsForm]),
  Val     = erl_eval:exprs( AbsForm
                          , erl_eval:new_bindings()),
  edts_rte_app:debug("Valg:~p~n", [Val]),
  {value, Value,_Bs} = Val,
  edts_rte_app:debug("val:~p~n", [Value]),
  Value.

expand_records(RT, E0) ->
  UsedRecords = used_record_defs(E0, RT),
  do_expand_records(UsedRecords, E0).

%% @doc Extract all the line numbers of all the clauses from an abstract form
%%      for both anonymous function and normal function
extract_fun_clauses_line_num({'fun', _L, {clauses, Clauses}}) ->
  extract_clauses_line_num(Clauses);
extract_fun_clauses_line_num({function, _L, _Func, _Arity, Clauses}) ->
  extract_clauses_line_num(Clauses).

extract_clauses_line_num([]) ->
  [];
extract_clauses_line_num([{clause,L,_ArgList0,_WhenList0,Exprs0}|T]) ->
  ExprsLn = extract_exprs_line_num(Exprs0),
  [ #clause_struct{line = L, sub_clause = ExprsLn}
  | extract_clauses_line_num(T)].

extract_exprs_line_num(Exprs) ->
  lists:foldl(fun(Expr, LineNums) ->
                case extract_expr_line_num(Expr) of
                  []  -> LineNums;
                  Lns -> lists:reverse([Lns|LineNums])
                end
              end, [], Exprs).

extract_expr_line_num(Exprs) when is_list(Exprs)         ->
  ples(Exprs);
extract_expr_line_num({cons, _L, Expr, Rest})            ->
  ple(Rest) ++ ple(Expr);
extract_expr_line_num({tuple, _L, Exprs})                ->
  ples(Exprs);
extract_expr_line_num({match,_L,LExpr,RExpr})            ->
  ple(RExpr) ++ ple(LExpr);
extract_expr_line_num({op, _L, _Ops, Expr})              ->
  ple(Expr);
extract_expr_line_num({op, _L, _Ops, LExpr, RExpr})      ->
  ple(RExpr) ++ ple(LExpr);
extract_expr_line_num({lc, _L, Expr, GenExprs})          ->
  ples(GenExprs) ++ ple(Expr);
extract_expr_line_num({generate, _L, ResExp, GenExp})    ->
  ple(GenExp) ++ ple(ResExp);
extract_expr_line_num({'case', _L, CaseExpr, Clauses})   ->
  plc(Clauses) ++ ple(CaseExpr);
extract_expr_line_num({ 'try', _L, Exprs, PatternClauses
                      , ExceptionClauses, FinalExprs})   ->
  ple(FinalExprs) ++ plc(ExceptionClauses) ++
    plc(PatternClauses) ++ ple(Exprs);
extract_expr_line_num({'receive', _L, Clauses})          ->
  plc(Clauses);
extract_expr_line_num(_)                                 ->
  [].

%% Result is in the reserse order of Exprs
ples(Exprs) ->
  lists:foldl(fun(Expr, NewExprs) -> ple(Expr) ++ NewExprs end, [], Exprs).

ple(Expr) ->
  pl(Expr, fun extract_expr_line_num/1).

plc(Clauses) ->
  pl(Clauses, fun extract_clauses_line_num/1).

pl(Expr, F) ->
  case F(Expr) of
    L when is_list(L) -> L;
    E                 -> [E]
  end.

%% @doc traverse all the clauses and mark all the touched node
%%      if one of the clause in a group of clauses are touched,
%%      do not touch the rest of the clause.
traverse_clause_struct(_Line, []) ->
  [];
traverse_clause_struct(Line, [H|_T] = ClausesGroups) when is_list(H) ->
  SmallerLnF = fun(ClauseStructs) ->
                   ClauseStruct = hd(ClauseStructs),
                   ClauseStruct#clause_struct.line =< Line
               end,
  {SmallerLnClausesGroups, BiggerOrEqualLnClausesGroups} =
    lists:splitwith(SmallerLnF, ClausesGroups),
  do_traverse_clause_group(SmallerLnClausesGroups, Line) ++
    BiggerOrEqualLnClausesGroups;
traverse_clause_struct(Line, ClauseStructs) ->
  Touched =
    lists:any(fun(ClauseStruct) ->
                  ClauseStruct#clause_struct.touched
              end, ClauseStructs),
  SmallerLnF = fun(ClauseStruct) ->
                   ClauseStruct#clause_struct.line =< Line
               end,
  {SmallerLnClauses, BiggerOrEqualLnClauses} =
    lists:splitwith(SmallerLnF, ClauseStructs),
  do_traverse_clause_struct(SmallerLnClauses, Line, Touched) ++
    BiggerOrEqualLnClauses.

do_traverse_clause_group([], _Line) ->
  [];
do_traverse_clause_group(SmallerClassesGroup, Line) ->
  Reversed = lists:reverse(SmallerClassesGroup),
  lists:reverse([traverse_clause_struct(Line, hd(Reversed))|tl(Reversed)]).

do_traverse_clause_struct([], _line, _Touched) ->
  [];
do_traverse_clause_struct(SmallerLnClauses, Line, Touched) ->
  [ClauseStruct|T] = lists:reverse(SmallerLnClauses),
  %% check if other clauses in the same group has been touched.
  case Touched of
    true  -> case ClauseStruct#clause_struct.touched of
               true  -> lists:reverse([touch_clause(ClauseStruct, Line)|T]);
               false -> SmallerLnClauses
             end;
    false -> lists:reverse([touch_clause(ClauseStruct, Line)|T])
  end.

touch_clause(ClauseStruct, Line) ->
  SubClauseStruct0 = ClauseStruct#clause_struct.sub_clause,
  SubClauseStruct  = traverse_clause_struct(Line, SubClauseStruct0),
  ClauseStruct#clause_struct{ touched = true
                            , sub_clause = SubClauseStruct}.

read_and_add_records(Module, RT) ->
  read_and_add_records(Module, '_', [], [], RT).

%% @doc get the abstract code of a function. support anonymous
%%      function as well
get_function_abscode(Module, Function, Arity) ->
  case is_lambda(Function) of
    false ->
      edts_code:get_function_abscode(Module, Function, Arity);
    {true, FatherFun, FatherArity, DefSeq}  ->
      get_lambda_abscode(Module, FatherFun, FatherArity, DefSeq, Function)
  end.

%% @doc if an atom is the name of an anonymous function. the format is like
%%      the following:
%%      "-Funname/Arity-fun-N-"
%%      where Funname is the name of the function, Arity is the number of
%%      the arguments the function would take and N is the sequence of the
%%      anonymous function defined in Funname.
-spec is_lambda(Function :: atom()) ->
                   {true, function(), arity(), integer()} | false.
is_lambda(Function) ->
  FuncStr = atom_to_list(Function),
  case re:run(FuncStr, "-(.*)/(.*)-fun-(.*)-", [{capture, [1,2,3], list}]) of
    {match, [FatherFunStr, FatherArityStr, DefinedSeq]} ->
      {true, list_to_atom(FatherFunStr),
             list_to_integer(FatherArityStr),
             list_to_integer(DefinedSeq)};
    nomatch ->
      false
  end.

get_lambda_abscode(Module, FatherFun, FatherArity, DefSeq, Function) ->
  {ok, FunAbsForm} = edts_code:get_function_abscode( Module
                                                   , FatherFun, FatherArity),
  {ok, normalize_fun( lists:nth( DefSeq+1
                               , extract_lambda_abscode_from_fun(FunAbsForm))
                    , Function)}.

extract_lambda_abscode_from_fun({function, _L, _Name, _Arity, Clauses}) ->
  lists:sort(fun( {'fun', L1, {clauses, _Clauses1}}
                , {'fun', L2, {clauses, _Clauses2}}) ->
                 L2 > L1
             end, extract_lambda_abscode_from_clauses(Clauses)).

extract_lambda_abscode_from_clauses(Clauses) ->
  lists:foldl(fun(Clause, Acc) ->
                extract_lambda_abscode_from_clause(Clause) ++ Acc
              end, [], Clauses).

extract_lambda_abscode_from_clause({clause, _L, _ArgList, _WhenList, Exprs}) ->
  lists:foldl(fun(Expr, Acc) ->
                extract_lambda_abscode_from_expr(Expr) ++ Acc
              end, [], Exprs).

%% TODO: Need to extract the labmda abscode from more expressions.
%%       Really want a simpler way way of handling this.
extract_lambda_abscode_from_expr({'case', _L, CaseExpr, Clauses}) ->
  extract_lambda_abscode_from_expr(CaseExpr) ++
    extract_lambda_abscode_from_clauses(Clauses);
extract_lambda_abscode_from_expr({match, _L, _LExpr0, RExpr0}) ->
  extract_lambda_abscode_from_expr(RExpr0);
extract_lambda_abscode_from_expr({call, _L1, {remote, _L2, _M, _F}, Args}) ->
  lists:foldl(fun(Arg, Acc) ->
                extract_lambda_abscode_from_expr(Arg) ++ Acc
              end, [], Args);
extract_lambda_abscode_from_expr({'fun', _L, {clauses, Clauses}} = AbsCode) ->
  [AbsCode|extract_lambda_abscode_from_clauses(Clauses)];
extract_lambda_abscode_from_expr(_) ->
  [].

get_module_sorted_fun_info(M) ->
  FunAritys = int:functions(M),
  AllLineFunAritys = lists:foldl(
    fun([Fun, Arity], LineFunAritys) ->
        FunInfo = edts_code:get_function_info(M, Fun, Arity),
        {line, Line} = lists:keyfind(line, 1, FunInfo),
        [[Line, Fun, Arity] | LineFunAritys]
    end, [], FunAritys),
  lists:reverse(lists:sort(AllLineFunAritys)).

%% @doc The name of the ETS table to store the tuple representation of
%%      the records
-spec record_table_name() -> atom().
record_table_name() ->
  edts_rte_record_table.

%% @doc When MFA and depth are the same, check if it is still a
%%      differnet function call.
%%      This could happen when:
%%      1) Tail recursion
%%      2) When function with the same name are called within the
%%         same expression.
%%         e.g.
%%         fib(N) ->
%%           fib(N-1) + fib(N-2)
%%
%%         In the example above, fib(N-2) will be called immediately
%%         after fib(N-1) is returned, making them have the same MFA
%%         and Depth.
%%
%%      To check this, we need to see if the the new line is either in
%%      the other clause of the same function or it is in the same clause
%%      but the new line is equal or smaller than the previous line.
-spec is_tail_call([clause_struct()], non_neg_integer(), non_neg_integer())
                  -> boolean().
is_tail_call(ClauseStructs, PreviousLine, NewLine) ->
  edts_rte_app:debug("8) is_tail_call:~p~n"
            , [[ClauseStructs, PreviousLine, NewLine]]),
  {LineSmallerClauses, _LineBiggerClauses} =
    lists:splitwith(fun(#clause_struct{line = L}) ->
                      L =< NewLine
                    end, ClauseStructs),
  edts_rte_app:debug("9) LineSmaller:~p~nLineBigger:~p~n"
            , [LineSmallerClauses, _LineBiggerClauses]),
  #clause_struct{touched = Touched, line = L} =
    hd(lists:reverse(LineSmallerClauses)),
  case Touched of
    false -> true;
    true  ->
      %% assert
      true = PreviousLine >= L,
      %% if previous line is bigger or equal than the new line, then it
      %% should be a tail recursion
      PreviousLine >= NewLine
  end.


%%%_* Internal =================================================================
read_and_add_records(Module, Selected, Options, Bs, RT) ->
  Info             = edts_code:get_module_info(Module, basic),
  {source, Source} = lists:keyfind(source, 1, Info),
  case read_records(Source, Selected, Options) of
    RAs when is_list(RAs) ->
      add_records(RAs, Bs, RT);
    Error ->
      Error
  end.

read_records(File, Selected, Options) ->
  case read_records(File, listify(Options)) of
    Error when is_tuple(Error) ->
      Error;
    RAs when Selected =:= '_' ->
      RAs;
    RAs ->
      Sel = listify(Selected),
      [RA || {attribute,_,_,{Name,_}}=RA <- RAs,
             lists:member(Name, Sel)]
  end.

add_records(RAs, Bs0, RT) ->
  Recs = [{Name,D} || {attribute,_,_,{Name,_}}=D <- RAs],
  Bs1 = record_bindings(Recs, Bs0),
  case check_command([], Bs1) of
    {error,{_Line,M,ErrDesc}} ->
      %% A source file that has not been compiled.
      ErrStr = io_lib:fwrite(<<"~s">>, [M:format_error(ErrDesc)]),
      exit(lists:flatten(ErrStr));
    ok ->
      true = ets:insert(RT, Recs),
      lists:usort([Name || {Name,_} <- Recs])
  end.

listify(L) when is_list(L) ->
  L;
listify(E) ->
  [E].

read_records(FileOrModule, Opts0) ->
  Opts = lists:delete(report_warnings, Opts0),
  case find_file(FileOrModule) of
    {files,[File]} ->
      read_file_records(File, Opts);
    {files,Files} ->
      lists:flatmap(fun(File) ->
                        case read_file_records(File, Opts) of
                          RAs when is_list(RAs) -> RAs;
                          _ -> []
                        end
                    end, Files);
    Error ->
      Error
  end.

%% Note that a sequence number is used here to make sure that if a
%% record is used by another record, then the first record is parsed
%% before the second record. (erl_eval:check_command() calls the
%% linter which needs the records in a proper order.)
record_bindings([], Bs) ->
  Bs;
record_bindings(Recs0, Bs0) ->
  {Recs1, _} = lists:mapfoldl(fun ({Name,Def}, I) -> {{Name,I,Def},I+1}
                              end, 0, Recs0),
  Recs2 = lists:keysort(2, lists:ukeysort(1, Recs1)),
  lists:foldl(fun ({Name,I,Def}, Bs) ->
                  erl_eval:add_binding({record,I,Name}, Def, Bs)
              end, Bs0, Recs2).

check_command(Es, Bs) ->
  erl_eval:check_command(Es, strip_bindings(Bs)).

find_file(Mod) when is_atom(Mod) ->
  case code:which(Mod) of
      File when is_list(File) ->
        {files,[File]};
      preloaded ->
        {_M,_Bin,File} = code:get_object_code(Mod),
        {files,[File]};
      _Else -> % non_existing, interpreted, cover_compiled
        {error,nofile}
    end;
find_file(File) ->
  case catch filelib:wildcard(File) of
    {'EXIT',_} ->
      {error,invalid_filename};
    Files ->
      {files,Files}
  end.

read_file_records(File, Opts) ->
  case filename:extension(File) of
    ".beam" ->
      case beam_lib:chunks(File, [abstract_code,"CInf"]) of
        {ok,{_Mod,[{abstract_code,{Version,Forms}},{"CInf",CB}]}} ->
          case record_attrs(Forms) of
            [] when Version =:= raw_abstract_v1 ->
              [];
            [] ->
              %% If the version is raw_X, then this test
              %% is unnecessary.
              try_source(File, CB);
            Records ->
              Records
          end;
        {ok,{_Mod,[{abstract_code,no_abstract_code},{"CInf",CB}]}} ->
          try_source(File, CB);
        Error ->
          %% Could be that the "Abst" chunk is missing (pre R6).
          Error
      end;
    _ ->
      parse_file(File, Opts)
  end.

-spec strip_bindings(erl_eval:binding_struct()) -> erl_eval:binding_struct().

strip_bindings(Bs) ->
  Bs -- [B || {{module,_},_}=B <- Bs].

record_attrs(Forms) ->
  [A || A = {attribute,_,record,_D} <- Forms].

%% This is how the debugger searches for source files. See int.erl.
try_source(Beam, CB) ->
  Os = case lists:keyfind(options, 1, binary_to_term(CB)) of
         false -> [];
         {_, Os0} -> Os0
       end,
  Src0 = filename:rootname(Beam) ++ ".erl",
  case is_file(Src0) of
    true -> parse_file(Src0, Os);
    false ->
      EbinDir = filename:dirname(Beam),
      Src = filename:join([filename:dirname(EbinDir), "src",
                           filename:basename(Src0)]),
      case is_file(Src) of
        true -> parse_file(Src, Os);
        false -> {error, nofile}
      end
  end.

parse_file(File, Opts) ->
  Cwd = ".",
  Dir = filename:dirname(File),
  IncludePath = [Cwd,Dir|inc_paths(Opts)],
  case epp:parse_file(File, IncludePath, pre_defs(Opts)) of
    {ok,Forms} ->
      record_attrs(Forms);
    Error ->
      Error
  end.

pre_defs([{d,M,V}|Opts]) ->
  [{M,V}|pre_defs(Opts)];
pre_defs([{d,M}|Opts]) ->
  [M|pre_defs(Opts)];
pre_defs([_|Opts]) ->
  pre_defs(Opts);
pre_defs([]) -> [].

inc_paths(Opts) ->
  [P || {i,P} <- Opts, is_list(P)].

is_file(Name) ->
  case filelib:is_file(Name) of
    true ->
      not filelib:is_dir(Name);
    false ->
      false
  end.

used_record_defs(E, RT) ->
    %% Be careful to return a list where used records come before
    %% records that use them. The linter wants them ordered that way.
    UR = case used_records(E, [], RT) of
             [] ->
                 [];
             L0 ->
                 L1 = lists:zip(L0, lists:seq(1, length(L0))),
                 L2 = lists:keysort(2, lists:ukeysort(1, L1)),
                 [R || {R, _} <- L2]
         end,
    record_defs(RT, UR).

used_records(E, U0, RT) ->
    case used_records(E) of
        {name,Name,E1} ->
            U = used_records(ets:lookup(RT, Name), [Name | U0], RT),
            used_records(E1, U, RT);
        {expr,[E1 | Es]} ->
            used_records(Es, used_records(E1, U0, RT), RT);
        _ ->
            U0
    end.

used_records({record_index,_,Name,F}) ->
    {name, Name, F};
used_records({record,_,Name,Is}) ->
    {name, Name, Is};
used_records({record_field,_,R,Name,F}) ->
    {name, Name, [R | F]};
used_records({record,_,R,Name,Ups}) ->
    {name, Name, [R | Ups]};
used_records({record_field,_,R,F}) -> % illegal
    {expr, [R | F]};
used_records({call,_,{atom,_,record},[A,{atom,_,Name}]}) ->
    {name, Name, A};
used_records({call,_,{atom,_,is_record},[A,{atom,_,Name}]}) ->
    {name, Name, A};
used_records({call,_,{remote,_,{atom,_,erlang},{atom,_,is_record}},
              [A,{atom,_,Name}]}) ->
    {name, Name, A};
used_records({call,_,{atom,_,record_info},[A,{atom,_,Name}]}) ->
    {name, Name, A};
used_records({call,Line,{tuple,_,[M,F]},As}) ->
    used_records({call,Line,{remote,Line,M,F},As});
used_records(T) when is_tuple(T) ->
    {expr, tuple_to_list(T)};
used_records(E) ->
    {expr, E}.

record_defs(RT, Names) ->
    lists:flatmap(fun(Name) -> ets:lookup(RT, Name)
                  end, Names).

do_expand_records([], E0) ->
    E0;
do_expand_records(UsedRecords, E0) ->
    RecordDefs = [Def || {_Name,Def} <- UsedRecords],
    L = 1,
    E = prep_rec(E0),
    Forms = RecordDefs ++ [{function,L,foo,0,[{clause,L,[],[],[E]}]}],
    [{function,L,foo,0,[{clause,L,[],[],[NE]}]}] =
        erl_expand_records:module(Forms, [strict_record_tests]),
    prep_rec(NE).

prep_rec({value,_CommandN,_V}=Value) ->
    %% erl_expand_records cannot handle the history expansion {value,_,_}.
    {atom,Value,ok};
prep_rec({atom,{value,_CommandN,_V}=Value,ok}) ->
    %% Undo the effect of the previous clause...
    Value;
prep_rec(T) when is_tuple(T) -> list_to_tuple(prep_rec(tuple_to_list(T)));
prep_rec([E | Es]) -> [prep_rec(E) | prep_rec(Es)];
prep_rec(E) -> E.

%% @doc replace the temporary variables with the actual value in a function
-spec var_to_val_in_fun( FunBody       :: string()
                       , AllClausesLn  :: #clause_struct{}
                       , Bindings      :: edts_rte_server:bindings())
                       -> string().
var_to_val_in_fun(AbsForm, AllClausesLn, Bindings) ->
  %% Replace variable names with variables' value and
  %% combine the Token to function string again
  NewFunBody            = do_var_to_val_in_fun( AbsForm
                                              , AllClausesLn
                                              , Bindings),
  %% edts_rte_app:debug("New Body before flatten: ~p~n", [NewFunBody]),
  NewForm               = erl_pp:form(NewFunBody),
  lists:flatten(NewForm).

%% @doc replace variable names with values for a function
do_var_to_val_in_fun( {'fun', L, {clauses, Clauses0}}
                    , AllClausesLn, Bindings) ->
  Clauses = replace_var_with_val_in_clauses( Clauses0
                                           , AllClausesLn
                                           , Bindings),
  {'fun', L, {clauses, Clauses}};
do_var_to_val_in_fun( {function, L, FuncName, Arity, Clauses0}
                    , AllClausesLn, Bindings) ->
  Clauses = replace_var_with_val_in_clauses( Clauses0
                                           , AllClausesLn
                                           , Bindings),
  %% edts_rte_app:debug("Replaced Clauses are:~p~n", [Clauses0]),
  {function, L, FuncName, Arity, Clauses}.

%% @doc replace variable names with values in each of the clauses for
%%      anonymous functions.
%%      there are two differences between this function and @see
%%      replace_var_with_val_in_clauses.
%%      1) We don't need to care about if the function clause is executed
%%         or not. because this is just the definition of the anonymous
%%         function and it is not being executed yet.
%%      2) We need to consider the shadowing. e.g. if A is in the arglist
%%         of a function clause in the anonymous function, we can't replace
%%         the temporary variable A even if A is already defined from outside.
replace_var_with_val_in_lambda_clauses( Clauses, AllClausesLn
                                      , Binding0, ExpandRecord) ->
  lists:map(fun({clause,_L,ArgList,_WhenList0,_Lines0} = Clause) ->
                Vars = extract_vars(ArgList),
                Binding = lists:foldl(fun(Var, TmpBinding) ->
                                        lists:keydelete(Var, 1, TmpBinding)
                                      end, Binding0, Vars),
                do_replace_var_with_val_in_clause( Clause, AllClausesLn
                                                 , Binding, ExpandRecord)
            end, Clauses).

extract_vars(ArgList) ->
  lists:foldl(fun(Arg, Acc) ->
                extract_var(Arg) ++ Acc
              end, [], ArgList).

%% This needs to be extended to support more programming constructs
extract_var({var, _, VarName}) ->
  [VarName];
extract_var(_) ->
  [].


replace_var_with_val_in_clauses(Clauses, AllClausesLn, Binding) ->
  replace_var_with_val_in_clauses(Clauses, AllClausesLn, Binding, false).

%% @doc replace variable names with values in each of the clauses
replace_var_with_val_in_clauses(Clauses, AllClausesLn, Binding, ExpandRecord) ->
  lists:map(fun({clause,L,_ArgList0,_WhenList0,_Lines0} = Clause) ->
                case is_clause_touched(L, AllClausesLn) of
                  true  -> do_replace_var_with_val_in_clause( Clause
                                                            , AllClausesLn
                                                            , Binding
                                                            , ExpandRecord);
                  false -> Clause
                end
            end, Clauses).

is_clause_touched(_L, [])                                  ->
  false;
is_clause_touched(L, [H|T]) when is_list(H)                ->
  is_clause_touched(L, H) orelse is_clause_touched(L, T);
is_clause_touched(L, [H|_T]) when H#clause_struct.line > L ->
  false;
is_clause_touched(L, [H|T])                                ->
  (H#clause_struct.line =:= L andalso H#clause_struct.touched)
    orelse is_clause_touched(L, H#clause_struct.sub_clause)
    orelse is_clause_touched(L, T).

do_replace_var_with_val_in_clause( {clause,L,ArgList0,WhenList0,Lines0}
                                 , AllClausesLn, Binding, ExpandRecord) ->
  %% replace all the variables with values for all the exprs in argument list
  io:format("ArgLists0:~p~n",[ArgList0]),
  io:format("Binding:~p~n",[Binding]),
  ArgList  = replace_var_with_val_in_expr( ArgList0, AllClausesLn
                                         , Binding, ExpandRecord),
  %% replace variables' name with values in "when" list
  WhenList = replace_var_with_val_args(WhenList0, Binding),
  %% replace variables' name with values for each of the expressions
  Lines    = replace_var_with_val_in_expr( Lines0, AllClausesLn
                                         , Binding, ExpandRecord),
  {clause,L,ArgList,WhenList,Lines}.

replace_var_with_val_args([], _Bindings)->[];
replace_var_with_val_args([VarExpr0|T], Bindings) ->
  VarExpr = replace_var_with_val(VarExpr0, Bindings),
  [VarExpr | replace_var_with_val_args(T, Bindings)].

%% @doc replace the variable in a list of expressions with its actual valuex
replace_var_with_val_in_exprs(Exprs, ExecClausesLn, Bindings, ExpandRecord) ->
  lists:map(fun(Expr) ->
              replace_var_with_val_in_expr( Expr, ExecClausesLn
                                          , Bindings, ExpandRecord)
            end, Exprs).

%% @doc replace the variable in the expression with its actual value
%%      it takes two extra parameters. the line number of all the clauses
%%      that were executed and the binding information.
%%      last parameter indicates if we want to expand the record or not
%%      normally we don't but when it is the input arguments we should.
replace_var_with_val_in_expr([], _ECLn, _Bs, _Er)                         ->
  [];
replace_var_with_val_in_expr(Atom, _ECLn, _Bs, _Er) when is_atom(Atom)    ->
  Atom;
replace_var_with_val_in_expr({nil, L}, _ECLn, _Bs, _Er)                   ->
  {nil, L};
replace_var_with_val_in_expr({atom, _L, _A} = VarExpr, _ECLn, _Bs, _Er)   ->
  VarExpr;
replace_var_with_val_in_expr({bin, _L, _FS} = BinExpr, _ECLn, _Bs, _Er)     ->
  %% TODO: this might need more investigation as to how to replace
  %%       the values in the sub expressions
  BinExpr;
replace_var_with_val_in_expr({cons, L, Expr0, Rest0}, ECLn, Bs, Er)       ->
  Expr = replace_var_with_val_in_expr(Expr0, ECLn, Bs, Er),
  Rest = replace_var_with_val_in_expr(Rest0, ECLn, Bs, Er),
  {cons, L, Expr, Rest};
replace_var_with_val_in_expr({tuple, L, Exprs0}, ECLn, Bs, Er)            ->
  io:format("tuple exprs:~p~n", [Exprs0]),
  io:format("tuple bs:~p~n", [bs]),
  Exprs = replace_var_with_val_in_exprs(Exprs0, ECLn, Bs, Er),
  {tuple, L, Exprs};
replace_var_with_val_in_expr({float, _, _} = VarExpr, _ECLn, _Bs, _Er)    ->
  VarExpr;
replace_var_with_val_in_expr({integer, _, _} = VarExpr, _ECLn, _Bs, _Er)  ->
  VarExpr;
replace_var_with_val_in_expr({match,L,LExpr0,RExpr0}, ECLn, Bs, Er)       ->
  LExpr = replace_var_with_val_in_expr(LExpr0, ECLn, Bs, Er),
  RExpr = replace_var_with_val_in_expr(RExpr0, ECLn, Bs, Er),
  {match,L,LExpr,RExpr};
replace_var_with_val_in_expr({var, _, _} = VarExpr, _ECLn, Bs, _Er)       ->
  replace_var_with_val(VarExpr, Bs);
replace_var_with_val_in_expr({op, L, Ops, Expr0}, ECLn, Bs, Er)           ->
  Expr = replace_var_with_val_in_expr(Expr0, ECLn, Bs, Er),
  {op, L, Ops, Expr};
replace_var_with_val_in_expr({op, L, Ops, LExpr0, RExpr0}, ECLn, Bs, Er)  ->
  LExpr = replace_var_with_val_in_expr(LExpr0, ECLn, Bs, Er),
  RExpr = replace_var_with_val_in_expr(RExpr0, ECLn, Bs, Er),
  {op, L, Ops, LExpr, RExpr};
replace_var_with_val_in_expr( {call, L, {atom, L, F0}, ArgList}
                            , ECLn, Bs, Er)                               ->
  F = replace_var_with_val_in_expr(F0, ECLn, Bs, Er),
  {call, L, {atom, L, F}, replace_var_with_val_in_exprs(ArgList, ECLn, Bs, Er)};
replace_var_with_val_in_expr( {call, L, {var, L, _} = FunName, ArgList}
                            , ECLn, Bs, Er)                               ->
  FunVal = replace_var_with_val_in_expr(FunName, ECLn, Bs, Er),
  {call, L, FunVal, replace_var_with_val_in_exprs(ArgList, ECLn, Bs, Er)};
replace_var_with_val_in_expr( {call, L, {remote, L, M0, F0}, Args0}
                            , ECLn, Bs, Er)                               ->
  M = replace_var_with_val_in_expr(M0, ECLn, Bs, Er),
  F = replace_var_with_val_in_expr(F0, ECLn, Bs, Er),
  { call, L, {remote, L, M, F}
  , replace_var_with_val_in_exprs(Args0, ECLn, Bs, Er)};
replace_var_with_val_in_expr( {'case', L, CaseExpr0, Clauses0}
                            , ECLn, Bs, Er)                               ->
  CaseExpr = replace_var_with_val_in_expr(CaseExpr0, ECLn, Bs, Er),
  Clauses  = replace_var_with_val_in_clauses(Clauses0, ECLn, Bs, Er),
  {'case', L, CaseExpr, Clauses};
replace_var_with_val_in_expr( {string, _L, _Str} = String
                            , _ECLn, _Bs, _Er)                            ->
  String;
replace_var_with_val_in_expr( { 'try', L, Exprs0, PatternClauses0
                              , ExceptionClauses0, FinalExprs0}
                            , ECLn, Bs, Er)                               ->
  Exprs            = replace_var_with_val_in_exprs(Exprs0, ECLn, Bs, Er),
  PatternClauses   = replace_var_with_val_in_clauses( PatternClauses0
                                                    , ECLn, Bs, Er),
  ExceptionClauses = replace_var_with_val_in_clauses( ExceptionClauses0
                                                    , ECLn, Bs, Er),
  FinalExprs       = replace_var_with_val_in_exprs( FinalExprs0
                                                  , ECLn, Bs, Er),
  {'try', L, Exprs, PatternClauses, ExceptionClauses, FinalExprs};
replace_var_with_val_in_expr({lc, L, Expr0, GenExprs0}, ECLn, Bs, Er)     ->
  Expr     = replace_var_with_val_in_expr(Expr0, ECLn, Bs, Er),
  GenExprs = replace_var_with_val_in_exprs(GenExprs0, ECLn, Bs, Er),
  {lc, L, Expr, GenExprs};
replace_var_with_val_in_expr({generate, L, ResExp, GenExp}, ECLn, Bs, Er) ->
  { generate, L, replace_var_with_val_in_expr(ResExp, ECLn, Bs, Er)
  , replace_var_with_val_in_expr(GenExp, ECLn, Bs, Er)};
replace_var_with_val_in_expr({'receive', L, Clauses0}, ECLn, Bs, Er)      ->
  Clauses  = replace_var_with_val_in_clauses(Clauses0, ECLn, Bs, Er),
  {'receive', L, Clauses};
replace_var_with_val_in_expr( {'receive', L, Clauses0, Int, Exprs0}
                            , ECLn, Bs, Er)                               ->
  Clauses  = replace_var_with_val_in_clauses(Clauses0, ECLn, Bs, Er),
  Expr     = replace_var_with_val_in_exprs(Exprs0, ECLn, Bs, Er),
  {'receive', L, Clauses, Int, Expr};
replace_var_with_val_in_expr( {'fun', L, {clauses, Clauses0}}
                            , ECLn, Bs, Er)                               ->
  Clauses  = replace_var_with_val_in_lambda_clauses(Clauses0, ECLn, Bs, Er),
  {'fun', L, {clauses, Clauses}};
replace_var_with_val_in_expr( {record_index, L, Name, Expr0}
                            , ECLn, Bs, Er)                               ->
  Expr = replace_var_with_val_in_expr(Expr0, ECLn, Bs, Er),
  {record_index, L, Name, Expr};
replace_var_with_val_in_expr( {record_field, L, LExpr0, RExpr0}
                            , ECLn, Bs, Er)                               ->
  LExpr = replace_var_with_val_in_expr(LExpr0, ECLn, Bs, Er),
  RExpr = replace_var_with_val_in_expr(RExpr0, ECLn, Bs, Er),
  {record_field, L, LExpr, RExpr};
replace_var_with_val_in_expr( {record_field, L, LExpr0, Name, RExpr0}
                            , ECLn, Bs, Er)                               ->
  LExpr = replace_var_with_val_in_expr(LExpr0, ECLn, Bs, Er),
  RExpr = replace_var_with_val_in_expr(RExpr0, ECLn, Bs, Er),
  {record_field, L, LExpr, Name, RExpr};
replace_var_with_val_in_expr( {record, L, Name, Fields0}, ECLn, Bs, Er)   ->
  Fields = replace_var_with_val_in_exprs(Fields0, ECLn, Bs, Er),
  case Er of
    true  ->
      expand_records(record_table_name(), {record, L, Name, Fields});
    false ->
      {record, L, Name, Fields}
  end;
replace_var_with_val_in_expr( {record, L, Var, Name, Fields0}
                            , ECLn, Bs, Er)                               ->
  Fields = replace_var_with_val_in_exprs(Fields0, ECLn, Bs, Er),
  case Er of
    true  ->
      expand_records(record_table_name(), {record, L, Var, Name, Fields});
    false ->
      {record, L, Var, Name, Fields}
  end;
replace_var_with_val_in_expr([Statement0|T], ECLn, Bs, Er)                ->
  Statement = replace_var_with_val_in_expr(Statement0, ECLn, Bs, Er),
  [Statement | replace_var_with_val_in_expr(T, ECLn, Bs, Er)];
replace_var_with_val_in_expr(Expr, _ECLn, _Bs, _Er)                       ->
  error({unexpected_expression, Expr}).

replace_var_with_val({var, L, VariableName}, Bs) ->
  case lists:keyfind(VariableName, 1, Bs) of
    {VariableName, Value} -> do_replace(VariableName, Value, L);
    false                 -> {var, L, VariableName}
  end;
replace_var_with_val(Other, _Bs)                 ->
  Other.

do_replace(VarName, Value0, L) ->
  Value       = maybe_convert_to_str(Value0),
  ReplacedStr = make_replaced_str(VarName, Value),
  Tokens      = get_tokens(ReplacedStr),
  {ok, [ValForm]}  = erl_parse:parse_exprs(Tokens),
  replace_line_num(ValForm, L).

make_replaced_str(VarName, Value) ->
  lists:flatten(io_lib:format( "{b,~p,s,~p,e}."
                             , [VarName, Value])).

get_tokens(ValStr) ->
  {ok, Tokens, _} = erl_scan:string(ValStr),
  Tokens.

%% @doc for values such as Pid and Func, which are not valid
%%      erlang terms, convert them to atom and return back.
maybe_convert_to_str(Value) ->
  Str0   = lists:flatten(io_lib:format("~p", [Value])),
  Str    = string:concat(Str0, "."),
  Tokens = get_tokens(Str),
  Spec   = [ {fun is_pid_tokens/1, "pid: "}
           , {fun is_func_tokens/1, "fun: "}],
  convert_with_spec(Spec, Value, Str0, Tokens).

convert_with_spec([], Value, _Str, _Tokens)                            ->
  Value;
convert_with_spec([{Predicate, StrPrefix} | Rest], Value, Str, Tokens) ->
  case Predicate(Tokens) of
    true  -> string:concat(StrPrefix,Str);
    false -> convert_with_spec(Rest, Value, Str, Tokens)
  end.

is_pid_tokens(Tokens) ->
  [FirstElem | _] = Tokens,
  [{dot, _}, LastElem | _] = lists:reverse(Tokens),
  is_left_arrow(FirstElem) andalso is_right_arrow(LastElem).

is_func_tokens([{'#', _}, {var, _, 'Fun'} | _Rest]) ->
  true;
is_func_tokens(_) ->
  false.

is_left_arrow({Char, _}) when Char =:= '<' ->
  true;
is_left_arrow(_) ->
  false.

is_right_arrow({Char, _}) when Char =:= '>' ->
  true;
is_right_arrow(_) ->
  false.

replace_line_num({A, _L0, C, D}, L)               ->
  {A, L, replace_line_num(C, L), replace_line_num(D, L)};
replace_line_num({A, _L0, C},    L)               ->
  {A, L, replace_line_num(C, L)};
replace_line_num({A, _L0},       L)               ->
  {A, L};
replace_line_num(Others,  L) when is_list(Others) ->
  lists:map(fun(Other) ->
                replace_line_num(Other, L)
            end, Others);
replace_line_num(Other,  _L)                      ->
  Other.

normalize_fun({'fun', L, {clauses, Clauses}}, Function) ->
  {clause,_L,ArgList,_WhenList,_Lines} = hd(Clauses),
  {function, L, Function, length(ArgList), Clauses}.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
