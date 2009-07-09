/*  $Id$

    Part of SWI-Prolog

    Author:        Markus Triska
    E-mail:        triska@gmx.at
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2007-2009 Markus Triska

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Thanks to Tom Schrijvers for his "bounds.pl", the first finite
   domain constraint solver included with SWI-Prolog. I've learned a
   lot from it and could even use some of the code for this solver.
   The propagation queue idea is taken from "prop.pl", a prototype
   solver also written by Tom. Highlights of the present solver:

   Symbolic constants for infinities
   ---------------------------------

   ?- X #>= 0, Y #=< 0.
   %@ X in 0..sup,
   %@ Y in inf..0.

   No artificial limits (using GMP)
   ---------------------------------

   ?- N is 2^66, X #\= N.
   %@ N = 73786976294838206464,
   %@ X in inf..73786976294838206463\/73786976294838206465..sup.

   Often stronger propagation
   ---------------------------------

   ?- Y #= abs(X), Y #\= 3, Z * Z #= 4.
   %@ Y in 0..2\/4..sup,
   %@ Y#=abs(X),
   %@ X in inf.. -4\/ -2..2\/4..sup,
   %@ Z in -2\/2.

   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

   Many things can be improved; if you want to help, feel free to
   e-mail me. A good starting point is taking a propagation algorithm
   from the literature and adding it - for example:

   J-C. Régin: "A filtering algorithm for constraints of difference in
   CSPs", AAAI-94, Seattle, WA, USA, pp 362--367, 1994.

   You can implement this algorithm without any knowledge of Prolog or
   this library. Just write an efficient C function that, given a set
   of variables and their list of domain elements, uses the described
   algorithm to compute the set of arcs that can be safely removed
   from the value graph.

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

:- module(clpfd, [
                  op(760, yfx, #<==>),
                  op(750, xfy, #==>),
                  op(750, yfx, #<==),
                  op(740, yfx, #\/),
                  op(730, yfx, #\),
                  op(720, yfx, #/\),
                  op(710,  fy, #\),
                  op(700, xfx, #>),
                  op(700, xfx, #<),
                  op(700, xfx, #>=),
                  op(700, xfx, #=<),
                  op(700, xfx, #=),
                  op(700, xfx, #\=),
                  op(700, xfx, in),
                  op(700, xfx, ins),
                  op(450, xfx, ..), % should bind more tightly than \/
                  (#>)/2,
                  (#<)/2,
                  (#>=)/2,
                  (#=<)/2,
                  (#=)/2,
                  (#\=)/2,
                  (#\)/1,
                  (#<==>)/2,
                  (#==>)/2,
                  (#<==)/2,
                  (#\/)/2,
                  (#/\)/2,
                  in/2,
                  ins/2,
                  all_different/1,
                  all_distinct/1,
                  sum/3,
                  tuples_in/2,
                  labeling/2,
                  label/1,
                  indomain/1,
                  lex_chain/1,
                  serialized/2,
                  element/3,
                  zcompare/3,
                  chain/2,
                  fd_var/1,
                  fd_inf/2,
                  fd_sup/2,
                  fd_size/2,
                  fd_dom/2
                 ]).


:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(pairs)).

:- op(700, xfx, cis).
:- op(700, xfx, cis_geq).
:- op(700, xfx, cis_gt).
:- op(700, xfx, cis_leq).
:- op(700, xfx, cis_lt).

/** <module> Constraint Logic Programming over Finite Domains

Constraint programming is a declarative formalism that lets you
describe conditions a solution must satisfy. This library provides
CLP(FD), Constraint Logic Programming over Finite Domains. It can be
used to model and solve various combinatorial problems such as
planning, scheduling and allocation tasks.

Most predicates of this library are finite domain _constraints_, which
are relations over integers. They generalise arithmetic evaluation of
integer expressions in that propagation can proceed in all directions.
This library also provides _enumeration_ _predicates_, which let you
systematically search for solutions on variables whose domains have
become finite. A finite domain _expression_ is one of:

    | an integer         | Given value                   |
    | a variable         | Unknown value                 |
    | -Expr              | Unary minus                   |
    | Expr + Expr        | Addition                      |
    | Expr * Expr        | Multiplication                |
    | Expr - Expr        | Subtraction                   |
    | min(Expr,Expr)     | Minimum of two expressions    |
    | max(Expr,Expr)     | Maximum of two expressions    |
    | Expr mod Expr      | Remainder of integer division |
    | abs(Expr)          | Absolute value                |
    | Expr / Expr        | Integer division              |

The most important finite domain constraints are:

    | Expr1 #>= Expr2  | Expr1 is larger than or equal to Expr2  |
    | Expr1 #=< Expr2  | Expr1 is smaller than or equal to Expr2 |
    | Expr1 #=  Expr2  | Expr1 equals Expr2 |
    | Expr1 #\= Expr2  | Expr1 is not equal to Expr2 |
    | Expr1 #> Expr2   | Expr1 is strictly larger than Expr2 |
    | Expr1 #< Expr2   | Expr1 is strictly smaller than Expr2 |

The constraints in/2, #=/2, #\=/2, #</2, #>/2, #=</2, and #>=/2 can be
_reified_, which means reflecting their truth values into Boolean
values represented by the integers 0 and 1. Let P and Q denote
reifiable constraints or Boolean variables, then:

    | #\ Q      | True iff Q is false             |
    | P #\/ Q   | True iff either P or Q          |
    | P #/\ Q   | True iff both P and Q           |
    | P #<==> Q | True iff P and Q are equivalent |
    | P #==> Q  | True iff P implies Q            |
    | P #<== Q  | True iff Q implies P            |

The constraints of this table are reifiable as well. If a variable
occurs at the place of a constraint that is being reified, it is
implicitly constrained to the Boolean values 0 and 1. Therefore, the
following queries all fail: ?- #\ 2., ?- #\ #\ 2. etc.

A common usage of this library is to first post the desired
constraints among the variables of a model, and then to use
enumeration predicates to search for solutions. As an example of a
constraint satisfaction problem, consider the cryptoarithmetic puzzle
SEND + MORE = MONEY, where different letters denote distinct integers
between 0 and 9. It can be modeled in CLP(FD) as follows:

==
:- use_module(library(clpfd)).

puzzle([S,E,N,D] + [M,O,R,E] = [M,O,N,E,Y]) :-
        Vars = [S,E,N,D,M,O,R,Y],
        Vars ins 0..9,
        all_different(Vars),
                  S*1000 + E*100 + N*10 + D +
                  M*1000 + O*100 + R*10 + E #=
        M*10000 + O*1000 + N*100 + E*10 + Y,
        M #\= 0, S #\= 0.
==

Sample query and its result:

==
?- puzzle(As+Bs=Cs).
As = [9, _G10107, _G10110, _G10113],
Bs = [1, 0, _G10128, _G10107],
Cs = [1, 0, _G10110, _G10107, _G10152],
_G10107 in 4..7,
1000*9+91*_G10107+ -90*_G10110+_G10113+ -9000*1+ -900*0+10*_G10128+ -1*_G10152#=0,
all_different([_G10107, _G10110, _G10113, _G10128, _G10152, 0, 1, 9]),
_G10110 in 5..8,
_G10113 in 2..8,
_G10128 in 2..8,
_G10152 in 2..8.
==

Here, the constraint solver has deduced more stringent bounds for all
variables. Keeping the modeling part separate from the search lets you
view these residual goals, observe termination and determinism
properties of the modeling part in isolation from the search, and more
easily experiment with different search strategies. Labeling can then
be used to search for solutions:

==
?- puzzle(As+Bs=Cs), label(As).
As = [9, 5, 6, 7],
Bs = [1, 0, 8, 5],
Cs = [1, 0, 6, 5, 2] ;
false.
==

In this case, it suffices to label a subset of variables to find the
puzzle's unique solution, since the constraint solver is strong enough
to reduce the domains of remaining variables to singleton sets. In
general though, it is necessary to label all variables to obtain
ground solutions.

You can also use CLP(FD) constraints as a more declarative alternative
for ordinary integer arithmetic with is/2, >/2 etc. For example:

==
:- use_module(library(clpfd)).

fac(0, 1).
fac(N, F) :- N #> 0, N1 #= N - 1, F #= N * F1, fac(N1, F1).
==

This predicate can be used in all directions. For example:

==
?- fac(47, F).
F = 258623241511168180642964355153611979969197632389120000000000 ;
false.

?- fac(N, 1).
N = 0 ;
N = 1 ;
false.

?- fac(N, 3).
false.
==

To make the predicate terminate if any argument is instantiated, add
the (implied) constraint F #\= 0 before the recursive call. Otherwise,
the query fac(N, 0) is the only non-terminating case of this kind.

This library uses goal_expansion/2 to rewrite constraints at
compilation time. The expansion's aim is to transparently bring the
performance of CLP(FD) constraints close to that of conventional
arithmetic predicates (</2, =:=/2, is/2 etc.) when the constraints are
used in modes that can also be handled by built-in arithmetic. To
disable the expansion, set the flag clpfd_goal_expansion to false.

Use call_residue_vars/2 and copy_term/3 to inspect residual goals and
the constraints in which a variable is involved. This library also
provides _reflection_ predicates (like fd_dom/2, fd_size/2 etc.) with
which you can inspect a variable's current domain. These predicates
can be useful if you want to implement your own labeling strategies.

You can also define custom constraints. The mechanism to do this is
not yet finalised, and we welcome suggestions and descriptions of use
cases that are important to you. As an example of how it can be done
currently, let us define a new custom constraint "oneground(X,Y,Z)",
where Z shall be 1 if at least one of X and Y is instantiated:

==
:- use_module(library(clpfd)).

:- multifile clpfd:run_propagator/2.

oneground(X, Y, Z) :-
        clpfd:make_propagator(oneground(X, Y, Z), Prop),
        clpfd:init_propagator(X, Prop),
        clpfd:init_propagator(Y, Prop),
        clpfd:trigger_once(Prop).

clpfd:run_propagator(oneground(X, Y, Z), MState) :-
        (   integer(X) -> clpfd:kill(MState), Z = 1
        ;   integer(Y) -> clpfd:kill(MState), Z = 1
        ;   true
        ).
==

First, clpfd:make_propagator/2 is used to transform a user-defined
representation of the new constraint to an internal form. With
clpfd:init_propagator/2, this internal form is then attached to X and
Y. From now on, the propagator will be invoked whenever the domains of
X or Y are changed. Then, clpfd:trigger_once/1 is used to give the
propagator its first chance for propagation even though the variables'
domains have not yet changed. Finally, clpfd:run_propagator/2 is
extended to define the actual propagator. As explained, this predicate
is automatically called by the constraint solver. The first argument
is the user-defined representation of the constraint as used in
clpfd:make_propagator/2, and the second argument is a mutable state
that can be used to prevent further invocations of the propagator when
the constraint has become entailed, by using clpfd:kill/1. An example
of using the new constraint:

==
?- oneground(X, Y, Z), Y = 5.
Y = 5,
Z = 1,
X in inf..sup.
==

@author Markus Triska
*/

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   A bound is either:

   n(N):    integer N
   inf:     infimum of Z (= negative infinity)
   sup:     supremum of Z (= positive infinity)
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

is_bound(n(N)) :- integer(N).
is_bound(inf).
is_bound(sup).

defaulty_to_bound(D, P) :- ( integer(D) -> P = n(D) ; P = D ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Compactified is/2 and predicates for several arithmetic expressions
   with infinities, tailored for the modes needed by this solver.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

% cis_gt only works for terms of depth 0 on both sides
cis_gt(n(N), B) :- cis_gt_numeric(B, N).
cis_gt(sup, B0) :- B0 \== sup.

cis_gt_numeric(n(B), A) :- A > B.
cis_gt_numeric(inf, _).

cis_geq(A, B) :-
        (   cis_gt(A, B) -> true
        ;   A == B
        ).

cis_geq_zero(sup).
cis_geq_zero(n(N)) :- N >= 0.

cis_lt(A, B)  :- cis_gt(B, A).

cis_leq(A, B) :- cis_geq(B, A).

cis_min(inf, _, inf).
cis_min(sup, B, B).
cis_min(n(N), B, Min) :- cis_min_(B, N, Min).

cis_min_(inf, _, inf).
cis_min_(sup, N, n(N)).
cis_min_(n(B), A, n(M)) :- M is min(A,B).

cis_max(sup, _, sup).
cis_max(inf, B, B).
cis_max(n(N), B, Max) :- cis_max_(B, N, Max).

cis_max_(inf, N, n(N)).
cis_max_(sup, _, sup).
cis_max_(n(B), A, n(M)) :- M is max(A,B).

cis_plus(inf, _, inf).
cis_plus(sup, _, sup).
cis_plus(n(A), B, Plus) :- cis_plus_(B, A, Plus).

cis_plus_(sup, _, sup).
cis_plus_(inf, _, inf).
cis_plus_(n(B), A, n(S)) :- S is A + B.

cis_minus(inf, _, inf).
cis_minus(sup, _, sup).
cis_minus(n(A), B, M) :- cis_minus_(B, A, M).

cis_minus_(inf, _, sup).
cis_minus_(sup, _, inf).
cis_minus_(n(B), A, n(M)) :- M is A - B.

cis_uminus(inf, sup).
cis_uminus(sup, inf).
cis_uminus(n(A), n(B)) :- B is -A.

cis_abs(inf, sup).
cis_abs(sup, sup).
cis_abs(n(A), n(B)) :- B is abs(A).

cis_times(inf, B, P) :-
        (   B cis_lt n(0) -> P = sup
        ;   B cis_gt n(0) -> P = inf
        ;   P = n(0)
        ).
cis_times(sup, B, P) :-
        (   B cis_gt n(0) -> P = sup
        ;   B cis_lt n(0) -> P = inf
        ;   P = n(0)
        ).
cis_times(n(N), B, P) :- cis_times_(B, N, P).

cis_times_(inf, A, P)     :- cis_times(inf, n(A), P).
cis_times_(sup, A, P)     :- cis_times(sup, n(A), P).
cis_times_(n(B), A, n(P)) :- P is A * B.

% compactified is/2 for expressions of interest

goal_expansion(A cis B, Expansion) :-
        phrase(cis_goals(B, A), Goals),
        list_goal(Goals, Expansion).

cis_goals(V, V)          --> { var(V) }, !.
cis_goals(n(N), n(N))    --> [].
cis_goals(inf, inf)      --> [].
cis_goals(sup, sup)      --> [].
cis_goals(sign(A0), R)   --> cis_goals(A0, A), [cis_sign(A, R)].
cis_goals(abs(A0), R)    --> cis_goals(A0, A), [cis_abs(A, R)].
cis_goals(-A0, R)        --> cis_goals(A0, A), [cis_uminus(A, R)].
cis_goals(A0+B0, R)      -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_plus(A, B, R)].
cis_goals(A0-B0, R)      -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_minus(A, B, R)].
cis_goals(min(A0,B0), R) -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_min(A, B, R)].
cis_goals(max(A0,B0), R) -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_max(A, B, R)].
cis_goals(A0*B0, R)      -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_times(A, B, R)].
cis_goals(div(A0,B0), R) -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_div(A, B, R)].
cis_goals(A0//B0, R)     -->
        cis_goals(A0, A),
        cis_goals(B0, B),
        [cis_slash(A, B, R)].

list_goal([], true).
list_goal([C|Cs], Goal) :- list_goal_(Cs, C, Goal).

list_goal_([], G, G).
list_goal_([C|Cs], G0, G) :- list_goal_(Cs, (G0,C), G).


cis_sign(sup, n(1)).
cis_sign(inf, n(-1)).
cis_sign(n(N), n(S)) :-
        (   N < 0 -> S = -1
        ;   N > 0 -> S = 1
        ;   S = 0
        ).

cis_div(sup, Y, Z)  :- ( cis_geq_zero(Y) -> Z = sup ; Z = inf ).
cis_div(inf, Y, Z)  :- ( cis_geq_zero(Y) -> Z = inf ; Z = sup ).
cis_div(n(X), Y, Z) :- cis_div_(Y, X, Z).

cis_div_(sup, _, n(0)).
cis_div_(inf, _, n(0)).
cis_div_(n(Y), X, Z) :-
        (   Y =:= 0 -> (  X >= 0 -> Z = sup ; Z = inf )
        ;   Z0 is X // Y, Z = n(Z0)
        ).

cis_slash(sup, _, sup).
cis_slash(inf, _, inf).
cis_slash(n(N), B, S) :- cis_slash_(B, N, S).

cis_slash_(sup, _, n(0)).
cis_slash_(inf, _, n(0)).
cis_slash_(n(B), A, n(S)) :- S is A // B.


/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   A domain is a finite set of disjoint intervals. Internally, domains
   are represented as trees. Each node is one of:

   empty: empty domain.

   split(N, Left, Right)
      - split on integer N, with Left and Right domains whose elements are
        all less than and greater than N, respectively. The domain is the
        union of Left and Right, i.e., N is a hole.

   from_to(From, To)
      - interval (From-1, To+1); From and To are bounds

   Desiderata: rebalance domains; singleton intervals.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Type definition and inspection of domains.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

check_domain(D) :-
        (   var(D) -> instantiation_error(D)
        ;   is_domain(D) -> true
        ;   domain_error(clpfd_domain, D)
        ).

is_domain(empty).
is_domain(from_to(From,To)) :-
        is_bound(From), is_bound(To),
        From cis_leq To.
is_domain(split(S, Left, Right)) :-
        integer(S),
        is_domain(Left), is_domain(Right),
        all_less_than(Left, S),
        all_greater_than(Right, S).

all_less_than(empty, _).
all_less_than(from_to(From,To), S) :-
        From cis_lt n(S), To cis_lt n(S).
all_less_than(split(S0,Left,Right), S) :-
        S0 < S,
        all_less_than(Left, S),
        all_less_than(Right, S).

all_greater_than(empty, _).
all_greater_than(from_to(From,To), S) :-
        From cis_gt n(S), To cis_gt n(S).
all_greater_than(split(S0,Left,Right), S) :-
        S0 > S,
        all_greater_than(Left, S),
        all_greater_than(Right, S).

default_domain(from_to(inf,sup)).

domain_infimum(from_to(I, _), I).
domain_infimum(split(_, Left, _), I) :- domain_infimum(Left, I).

domain_supremum(from_to(_, S), S).
domain_supremum(split(_, _, Right), S) :- domain_supremum(Right, S).

domain_num_elements(empty, n(0)).
domain_num_elements(from_to(From,To), Num) :- Num cis To - From + n(1).
domain_num_elements(split(_, Left, Right), Num) :-
        domain_num_elements(Left, NL),
        domain_num_elements(Right, NR),
        Num cis NL + NR.

domain_direction_element(from_to(n(From), n(To)), Dir, E) :-
        (   Dir == up -> between(From, To, E)
        ;   between(From, To, E0),
            E is To - (E0 - From)
        ).
domain_direction_element(split(_, D1, D2), Dir, E) :-
        (   Dir == up ->
            (   domain_direction_element(D1, Dir, E)
            ;   domain_direction_element(D2, Dir, E)
            )
        ;   (   domain_direction_element(D2, Dir, E)
            ;   domain_direction_element(D1, Dir, E)
            )
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Test whether domain contains a given integer.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_contains(from_to(From,To), I) :-
        domain_contains_from(From, I),
        domain_contains_to(To, I).
domain_contains(split(S, Left, Right), I) :-
        (   I < S -> domain_contains(Left, I)
        ;   I > S -> domain_contains(Right, I)
        ).

domain_contains_from(inf, _).
domain_contains_from(n(L), I) :- L =< I.

domain_contains_to(sup, _).
domain_contains_to(n(U), I) :- I =< U.

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Test whether a domain contains another domain.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_subdomain(Dom, Sub) :- domain_subdomain(Dom, Dom, Sub).

domain_subdomain(from_to(_,_), Dom, Sub) :-
        domain_subdomain_fromto(Sub, Dom).
domain_subdomain(split(_, _, _), Dom, Sub) :-
        domain_subdomain_split(Sub, Dom, Sub).

domain_subdomain_split(empty, _, _).
domain_subdomain_split(from_to(From,To), split(S,Left0,Right0), Sub) :-
        (   To cis_lt n(S) -> domain_subdomain(Left0, Left0, Sub)
        ;   From cis_gt n(S) -> domain_subdomain(Right0, Right0, Sub)
        ).
domain_subdomain_split(split(_,Left,Right), Dom, _) :-
        domain_subdomain(Dom, Dom, Left),
        domain_subdomain(Dom, Dom, Right).

domain_subdomain_fromto(empty, _).
domain_subdomain_fromto(from_to(From,To), from_to(From0,To0)) :-
        From0 cis_leq From, To0 cis_geq To.
domain_subdomain_fromto(split(_,Left,Right), Dom) :-
        domain_subdomain_fromto(Left, Dom),
        domain_subdomain_fromto(Right, Dom).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Remove an integer from a domain. The domain is traversed until an
   interval is reached from which the element can be removed, or until
   it is clear that no such interval exists.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_remove(empty, _, empty).
domain_remove(from_to(L0, U0), X, D) :- domain_remove_(L0, U0, X, D).
domain_remove(split(S, Left0, Right0), X, D) :-
        (   X =:= S -> D = split(S, Left0, Right0)
        ;   X < S ->
            domain_remove(Left0, X, Left1),
            (   Left1 == empty -> D = Right0
            ;   D = split(S, Left1, Right0)
            )
        ;   domain_remove(Right0, X, Right1),
            (   Right1 == empty -> D = Left0
            ;   D = split(S, Left0, Right1)
            )
        ).

%?- domain_remove(from_to(n(0),n(5)), 3, D).

domain_remove_(inf, U0, X, D) :-
        (   U0 == n(X) -> U1 is X - 1, D = from_to(inf, n(U1))
        ;   U0 cis_lt n(X) -> D = from_to(inf,U0)
        ;   L1 is X + 1, U1 is X - 1,
            D = split(X, from_to(inf, n(U1)), from_to(n(L1),U0))
        ).
domain_remove_(n(N), U0, X, D) :- domain_remove_upper(U0, N, X, D).

domain_remove_upper(sup, L0, X, D) :-
        (   L0 =:= X -> L1 is X + 1, D = from_to(n(L1),sup)
        ;   L0 > X -> D = from_to(n(L0),sup)
        ;   L1 is X + 1, U1 is X - 1,
            D = split(X, from_to(n(L0),n(U1)), from_to(n(L1),sup))
        ).
domain_remove_upper(n(U0), L0, X, D) :-
        (   L0 =:= U0, X =:= L0 -> D = empty
        ;   L0 =:= X -> L1 is X + 1, D = from_to(n(L1), n(U0))
        ;   U0 =:= X -> U1 is X - 1, D = from_to(n(L0), n(U1))
        ;   between(L0, U0, X) ->
            U1 is X - 1, L1 is X + 1,
            D = split(X, from_to(n(L0), n(U1)), from_to(n(L1), n(U0)))
        ;   D = from_to(n(L0),n(U0))
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Remove all elements greater than / less than a constant.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_remove_greater_than(empty, _, empty).
domain_remove_greater_than(from_to(From0,To0), G, D) :-
        (   From0 cis_gt n(G) -> D = empty
        ;   To cis min(To0,n(G)), D = from_to(From0,To)
        ).
domain_remove_greater_than(split(S,Left0,Right0), G, D) :-
        (   S =< G ->
            domain_remove_greater_than(Right0, G, Right),
            (   Right == empty -> D = Left0
            ;   D = split(S, Left0, Right)
            )
        ;   domain_remove_greater_than(Left0, G, D)
        ).

domain_remove_smaller_than(empty, _, empty).
domain_remove_smaller_than(from_to(From0,To0), V, D) :-
        (   To0 cis_lt n(V) -> D = empty
        ;   From cis max(From0,n(V)), D = from_to(From,To0)
        ).
domain_remove_smaller_than(split(S,Left0,Right0), V, D) :-
        (   S >= V ->
            domain_remove_smaller_than(Left0, V, Left),
            (   Left == empty -> D = Right0
            ;   D = split(S, Left, Right0)
            )
        ;   domain_remove_smaller_than(Right0, V, D)
        ).


/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Remove a whole domain from another domain. (Set difference.)
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_subtract(Dom0, Sub, Dom) :- domain_subtract(Dom0, Dom0, Sub, Dom).

domain_subtract(empty, _, _, empty).
domain_subtract(from_to(From0,To0), Dom, Sub, D) :-
        (   Sub == empty -> D = Dom
        ;   Sub = from_to(From,To) ->
            (   From == To -> From = n(X), domain_remove(Dom, X, D)
            ;   From cis_gt To0 -> D = Dom
            ;   To cis_lt From0 -> D = Dom
            ;   From cis_leq From0 ->
                (   To cis_geq To0 -> D = empty
                ;   From1 cis To + n(1),
                    D = from_to(From1, To0)
                )
            ;   To1 cis From - n(1),
                (   To cis_lt To0 ->
                    From = n(S),
                    From2 cis To + n(1),
                    D = split(S,from_to(From0,To1),from_to(From2,To0))
                ;   D = from_to(From0,To1)
                )
            )
        ;   Sub = split(S, Left, Right) ->
            (   n(S) cis_gt To0 -> domain_subtract(Dom, Dom, Left, D)
            ;   n(S) cis_lt From0 -> domain_subtract(Dom, Dom, Right, D)
            ;   domain_subtract(Dom, Dom, Left, D1),
                domain_subtract(D1, D1, Right, D)
            )
        ).
domain_subtract(split(S, Left0, Right0), _, Sub, D) :-
        domain_subtract(Left0, Left0, Sub, Left),
        domain_subtract(Right0, Right0, Sub, Right),
        (   Left == empty -> D = Right
        ;   Right == empty -> D = Left
        ;   D = split(S, Left, Right)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Complement of a domain
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_complement(D, C) :-
        default_domain(Default),
        domain_subtract(Default, D, C).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Convert domain to a list of disjoint intervals From-To.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_intervals(D, Is) :- phrase(domain_intervals(D), Is).

domain_intervals(split(_, Left, Right)) -->
        domain_intervals(Left), domain_intervals(Right).
domain_intervals(empty)                 --> [].
domain_intervals(from_to(From,To))      --> [From-To].

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   To compute the intersection of two domains D1 and D2, we choose D1
   as the reference domain. For each interval of D1, we compute how
   far and to which values D2 lets us extend it.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domains_intersection(D1, D2, Intersection) :-
        domains_intersection_(D1, D2, Intersection),
        Intersection \== empty.

domains_intersection_(empty, _, empty).
domains_intersection_(from_to(L0,U0), D2, Dom) :-
        narrow(D2, L0, U0, Dom).
domains_intersection_(split(S,Left0,Right0), D2, Dom) :-
        domains_intersection_(Left0, D2, Left1),
        domains_intersection_(Right0, D2, Right1),
        (   Left1 == empty -> Dom = Right1
        ;   Right1 == empty -> Dom = Left1
        ;   Dom = split(S, Left1, Right1)
        ).

narrow(empty, _, _, empty).
narrow(from_to(L0,U0), From0, To0, Dom) :-
        From1 cis max(From0,L0), To1 cis min(To0,U0),
        (   From1 cis_gt To1 -> Dom = empty
        ;   Dom = from_to(From1,To1)
        ).
narrow(split(S, Left0, Right0), From0, To0, Dom) :-
        (   To0 cis_lt n(S) -> narrow(Left0, From0, To0, Dom)
        ;   From0 cis_gt n(S) -> narrow(Right0, From0, To0, Dom)
        ;   narrow(Left0, From0, To0, Left1),
            narrow(Right0, From0, To0, Right1),
            (   Left1 == empty -> Dom = Right1
            ;   Right1 == empty -> Dom = Left1
            ;   Dom = split(S, Left1, Right1)
            )
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Union of 2 domains.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domains_union(D1, D2, Union) :-
        domain_intervals(D1, Is1),
        domain_intervals(D2, Is2),
        append(Is1, Is2, IsU0),
        merge_intervals(IsU0, IsU1),
        intervals_to_domain(IsU1, Union).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Shift the domain by an offset.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_shift(empty, _, empty).
domain_shift(from_to(From0,To0), O, from_to(From,To)) :-
        From cis From0 + n(O), To cis To0 + n(O).
domain_shift(split(S0, Left0, Right0), O, split(S, Left, Right)) :-
        S is S0 + O,
        domain_shift(Left0, O, Left),
        domain_shift(Right0, O, Right).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   The new domain contains all values of the old domain,
   multiplied by a constant multiplier.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_expand(D0, M, D) :-
        (   M < 0 ->
            domain_negate(D0, D1),
            M1 is abs(M),
            domain_expand_(D1, M1, D)
        ;   M =:= 1 -> D = D0
        ;   domain_expand_(D0, M, D)
        ).

domain_expand_(empty, _, empty).
domain_expand_(from_to(From0, To0), M, from_to(From,To)) :-
        From cis From0*n(M),
        To cis To0*n(M).
domain_expand_(split(S0, Left0, Right0), M, split(S, Left, Right)) :-
        S is M*S0,
        domain_expand_(Left0, M, Left),
        domain_expand_(Right0, M, Right).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   similar to domain_expand/3, tailored for division: an interval
   [From,To] is extended to [From*M, ((To+1)*M - 1)], i.e., to all
   values that integer-divided by M yield a value from interval.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_expand_more(D0, M, D) :-
        %format("expanding ~w by ~w\n", [D0,M]),
        (   M < 0 -> domain_negate(D0, D1), M1 is abs(M)
        ;   D1 = D0, M1 = M
        ),
        domain_expand_more_(D1, M1, D).
        %format("yield: ~w\n", [D]).

domain_expand_more_(empty, _, empty).
domain_expand_more_(from_to(From0, To0), M, from_to(From,To)) :-
        (   From0 cis_lt n(0) ->
            From cis (From0-n(1))*n(M) + n(1)
        ;   From cis From0*n(M)
        ),
        (   To0 cis_lt n(0) ->
            To cis To0*n(M)
        ;   To cis (To0+n(1))*n(M) - n(1)
        ).
domain_expand_more_(split(S0, Left0, Right0), M, D) :-
        S is M*S0,
        domain_expand_more_(Left0, M, Left),
        domain_expand_more_(Right0, M, Right),
        domain_supremum(Left, LeftSup),
        domain_infimum(Right, RightInf),
        (   LeftSup cis_lt n(S), n(S) cis_lt RightInf ->
            D = split(S, Left, Right)
        ;   domain_infimum(Left, Inf),
            domain_supremum(Right, Sup),
            D = from_to(Inf, Sup)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Scale a domain down by a constant multiplier. Assuming (//)/2.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_contract(D0, M, D) :-
        %format("contracting ~w by ~w\n", [D0,M]),
        (   M < 0 -> domain_negate(D0, D1), M1 is abs(M)
        ;   D1 = D0, M1 = M
        ),
        domain_contract_(D1, M1, D).

domain_contract_(empty, _, empty).
domain_contract_(from_to(From0, To0), M, from_to(From,To)) :-
        (   cis_geq_zero(From0) ->
            From cis (From0 + n(M) - n(1)) // n(M)
        ;   From cis From0 // n(M)
        ),
        (   cis_geq_zero(To0) ->
            To cis To0 // n(M)
        ;   To cis (To0 - n(M) + n(1)) // n(M)
        ).
domain_contract_(split(S0,Left0,Right0), M, D) :-
        S is S0 // M,
        %  Scaled down domains do not necessarily retain any holes of
        %  the original domain.
        domain_contract_(Left0, M, Left),
        domain_contract_(Right0, M, Right),
        domain_supremum(Left, LeftSup),
        domain_infimum(Right, RightInf),
        (   LeftSup cis_lt n(S), n(S) cis_lt RightInf ->
            D = split(S, Left, Right)
        ;   domain_infimum(Left0, Inf),
            % TODO: this is not necessarily an interval
            domain_supremum(Right0, Sup),
            min_divide(Inf, Sup, n(M), n(M), From0),
            max_divide(Inf, Sup, n(M), n(M), To0),
            domain_infimum(Left, LeftInf),
            domain_supremum(Right, RightSup),
            From cis max(LeftInf, From0),
            To cis min(RightSup, To0),
            D = from_to(From, To)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Similar to domain_contract, tailored for division, i.e.,
   {21,23} contracted by 4 is 5. It contracts "less".
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_contract_less(D0, M, D) :-
        (   M < 0 -> domain_negate(D0, D1), M1 is abs(M)
        ;   D1 = D0, M1 = M
        ),
        domain_contract_less_(D1, M1, D).

domain_contract_less_(empty, _, empty).
domain_contract_less_(from_to(From0, To0), M, from_to(From,To)) :-
        From cis From0 // n(M), To cis To0 // n(M).
domain_contract_less_(split(S0,Left0,Right0), M, D) :-
        S is S0 // M,
        %  Scaled down domains do not necessarily retain any holes of
        %  the original domain.
        domain_contract_less_(Left0, M, Left),
        domain_contract_less_(Right0, M, Right),
        domain_supremum(Left, LeftSup),
        domain_infimum(Right, RightInf),
        (   LeftSup cis_lt n(S), n(S) cis_lt RightInf ->
            D = split(S, Left, Right)
        ;   domain_infimum(Left0, Inf),
            % TODO: this is not necessarily an interval
            domain_supremum(Right0, Sup),
            min_divide_less(Inf, Sup, n(M), n(M), From0),
            max_divide_less(Inf, Sup, n(M), n(M), To0),
            domain_infimum(Left, LeftInf),
            domain_supremum(Right, RightSup),
            From cis max(LeftInf, From0),
            To cis min(RightSup, To0),
            D = from_to(From, To)
            %format("got: ~w\n", [D])
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Negate the domain. Left and Right sub-domains and bounds switch sides.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

domain_negate(empty, empty).
domain_negate(from_to(From0, To0), from_to(To,From)) :-
        From cis -From0, To cis -To0.
domain_negate(split(S0, Left0, Right0), split(S, Left, Right)) :-
        S is -S0,
        domain_negate(Left0, Right),
        domain_negate(Right0, Left).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Construct a domain from a list of integers. Try to balance it.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

list_to_disjoint_intervals([], []).
list_to_disjoint_intervals([N|Ns], Is) :-
        list_to_disjoint_intervals(Ns, N, N, Is).

list_to_disjoint_intervals([], M, N, [n(M)-n(N)]).
list_to_disjoint_intervals([B|Bs], M, N, Is) :-
        (   B =:= N + 1 ->
            list_to_disjoint_intervals(Bs, M, B, Is)
        ;   Is = [n(M)-n(N)|Rest],
            list_to_disjoint_intervals(Bs, B, B, Rest)
        ).

list_to_domain(List0, D) :-
        (   List0 == [] -> D = empty
        ;   sort(List0, List),
            list_to_disjoint_intervals(List, Is),
            intervals_to_domain(Is, D)
        ).

intervals_to_domain([], empty) :- !.
intervals_to_domain([M-N], from_to(M,N)) :- !.
intervals_to_domain(Is, D) :-
        length(Is, L),
        FL is L // 2,
        length(Front, FL),
        append(Front, Tail, Is),
        Tail = [n(Start)-_|_],
        Hole is Start - 1,
        intervals_to_domain(Front, Left),
        intervals_to_domain(Tail, Right),
        D = split(Hole, Left, Right).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% ?Var in +Domain
%
%  Var is an element of Domain. Domain is one of:
%
%         * Integer
%           Singleton set consisting only of _Integer_.
%         * Lower..Upper
%           All integers _I_ such that _Lower_ =< _I_ =< _Upper_.
%           _Lower_ must be an integer or the atom *inf*, which
%           denotes negative infinity. _Upper_ must be an integer or
%           the atom *sup*, which denotes positive infinity.
%         * Domain1 \/ Domain2
%           The union of Domain1 and Domain2.

V in D :-
        fd_variable(V),
        drep_to_domain(D, Dom),
        domain(V, Dom).

fd_variable(V) :-
        (   var(V) -> true
        ;   integer(V) -> true
        ;   type_error(integer, V)
        ).

%% +Vars ins +Domain
%
%  The variables in the list Vars are elements of Domain.

Vs ins D :-
        must_be(list, Vs),
        maplist(fd_variable, Vs),
        drep_to_domain(D, Dom),
        domains(Vs, Dom).

%% indomain(?Var)
%
% Bind Var to all feasible values of its domain on backtracking. The
% domain of Var must be finite.

indomain(Var) :- label([Var]).

order_dom_next(up, Dom, Next)   :- domain_infimum(Dom, n(Next)).
order_dom_next(down, Dom, Next) :- domain_supremum(Dom, n(Next)).


%% label(+Vars)
%
% Equivalent to labeling([], Vars).

label(Vs) :- labeling([], Vs).

%% labeling(+Options, +Vars)
%
% Labeling means systematically trying out values for the finite
% domain variables Vars until all of them are ground. The domain of
% each variable in Vars must be finite. Options is a list of options
% that let you exhibit some control over the search process. Several
% categories of options exist:
%
% The variable selection strategy lets you specify which variable of
% Vars is labeled next and is one of:
%
%   * leftmost
%   Label the variables in the order they occur in Vars. This is the
%   default.
%
%   * ff
%   _|First fail|_. Label the leftmost variable with smallest domain next,
%   in order to detect infeasibility early. This is often a good
%   strategy.
%
%   * ffc
%   Of the variables with smallest domains, the leftmost one
%   participating in most constraints is labeled next.
%
%   * min
%   Label the leftmost variable whose lower bound is the lowest next.
%
%   * max
%   Label the leftmost variable whose upper bound is the highest next.
%
% The value order is one of:
%
%   * up
%   Try the elements of the chosen variable's domain in ascending order.
%   This is the default.
%
%   * down
%   Try the domain elements in descending order.
%
% The branching strategy is one of:
%
%   * step
%   For each variable X, a choice is made between X = V and X #\= V,
%   where V is determined by the value ordering options. This is the
%   default.
%
%   * enum
%   For each variable X, a choice is made between X = V_1, X = V_2
%   etc., for all values V_i of the domain of X. The order is
%   determined by the value ordering options.
%
%   * bisect
%   For each variable X, a choice is made between X #=< M and X #> M,
%   where M is the midpoint of the domain of X.
%
% At most one option of each category can be specified, and an option
% must not occur repeatedly.
%
% The order of solutions can be influenced with:
%
%   * min(Expr)
%   * max(Expr)
%
% This generates solutions in ascending/descending order with respect
% to the evaluation of the arithmetic expression Expr. Labeling Vars
% must make Expr ground. If several such options are specified, they
% are interpreted from left to right, e.g.:
%
% ==
% ?- [X,Y] ins 10..20, labeling([max(X),min(Y)],[X,Y]).
% ==
%
% This generates solutions in descending order of X, and for each
% binding of X, solutions are generated in ascending order of Y. To
% obtain the incomplete behaviour that other systems exhibit with
% "maximize(Expr)" and "minimize(Expr)", use once/1, e.g.:
%
% ==
% once(labeling([max(Expr)], Vars))
% ==
%
% Labeling is always complete, always terminates, and yields no
% redundant solutions.
%

labeling(Options, Vars) :-
        must_be(list, Options),
        must_be(list, Vars),
        maplist(finite_domain, Vars),
        label(Options, Options, default(leftmost), default(up), default(step), [], upto_ground, Vars).

finite_domain(Var) :-
        (   fd_get(Var, Dom, _) ->
            (   domain_infimum(Dom, n(_)), domain_supremum(Dom, n(_)) -> true
            ;   instantiation_error(Var)
            )
        ;   integer(Var) -> true
        ;   must_be(integer, Var)
        ).


label([O|Os], Options, Selection, Order, Choice, Optim, Consistency, Vars) :-
        (   var(O)-> instantiation_error(O)
        ;   override(selection, Selection, O, Options, S1) ->
            label(Os, Options, S1, Order, Choice, Optim, Consistency, Vars)
        ;   override(order, Order, O, Options, O1) ->
            label(Os, Options, Selection, O1, Choice, Optim, Consistency, Vars)
        ;   override(choice, Choice, O, Options, C1) ->
            label(Os, Options, Selection, Order, C1, Optim, Consistency, Vars)
        ;   optimisation(O) ->
            label(Os, Options, Selection, Order, Choice, [O|Optim], Consistency, Vars)
        ;   consistency(O, O1) ->
            label(Os, Options, Selection, Order, Choice, Optim, O1, Vars)
        ;   domain_error(labeling_option, O)
        ).
label([], _, Selection, Order, Choice, Optim0, Consistency, Vars) :-
        maplist(arg(1), [Selection,Order,Choice], [S,O,C]),
        ( Optim0 == [] ->
            label(Vars, S, O, C, Consistency)
        ;   reverse(Optim0, Optim),
            exprs_singlevars(Optim, SVs),
            optimise(Vars, [S,O,C], SVs)
        ).

% Introduce new variables for each min/max expression to avoid
% reparsing expressions during optimisation.

exprs_singlevars([], []).
exprs_singlevars([E|Es], [SV|SVs]) :-
        E =.. [F,Expr],
        Single #= Expr,
        SV =.. [F,Single],
        exprs_singlevars(Es, SVs).

all_dead(fd_props(Bs,Gs,Os)) :-
        all_dead_(Bs),
        all_dead_(Gs),
        all_dead_(Os).

all_dead_([]).
all_dead_([propagator(_, S)|Ps]) :- S == dead, all_dead_(Ps).

label([], _, _, _, Consistency) :- !,
        (   Consistency = upto_in(I0,I) -> I0 = I
        ;   true
        ).
label(Vars, Selection, Order, Choice, Consistency) :-
        select_var(Selection, Vars, Var, RVars),
        (   var(Var) ->
            (   Consistency = upto_in(I0,I),
                fd_get(Var, _, Ps),
                all_dead(Ps) ->
                fd_size(Var, Size),
                I1 is I0*Size,
                label(RVars, Selection, Order, Choice, upto_in(I1,I))
            ;   Consistency = upto_in, fd_get(Var, _, Ps), all_dead(Ps) ->
                label(RVars, Selection, Order, Choice, Consistency)
            ;   choice_order_variable(Choice, Order, Var, RVars, Selection, Consistency)
            )
        ;   label(RVars, Selection, Order, Choice, Consistency)
        ).

choice_order_variable(step, Order, Var, Vars, Selection, Consistency) :-
        fd_get(Var, Dom, _),
        order_dom_next(Order, Dom, Next),
        (   Var = Next,
            label(Vars, Selection, Order, step, Consistency)
        ;   neq_num(Var, Next),
            do_queue,
            label([Var|Vars], Selection, Order, step, Consistency)
        ).
choice_order_variable(enum, Order, Var, Vars, Selection, Consistency) :-
        fd_get(Var, Dom0, _),
        domain_direction_element(Dom0, Order, Var),
        label(Vars, Selection, Order, enum, Consistency).
choice_order_variable(bisect, Order, Var, Vars, Selection, Consistency) :-
        fd_get(Var, Dom, _),
        domain_infimum(Dom, n(I)),
        domain_supremum(Dom, n(S)),
        Mid0 is (I + S) // 2,
        (   Mid0 =:= S -> Mid is Mid0 - 1 ; Mid = Mid0 ),
        (   Var #=< Mid,
            label([Var|Vars], Selection, Order, bisect, Consistency)
        ;   Var #> Mid,
            label([Var|Vars], Selection, Order, bisect, Consistency)
        ).

override(What, Prev, Value, Options, Result) :-
        call(What, Value),
        override_(Prev, Value, Options, Result).

override_(default(_), Value, _, user(Value)).
override_(user(Prev), Value, Options, _) :-
        (   Value == Prev ->
            domain_error(nonrepeating_labeling_options, Options)
        ;   domain_error(consistent_labeling_options, Options)
        ).

selection(ff).
selection(ffc).
selection(min).
selection(max).
selection(leftmost).

choice(step).
choice(enum).
choice(bisect).

order(up).
order(down).

consistency(upto_in(I), upto_in(1, I)).
consistency(upto_in, upto_in).
consistency(upto_ground, upto_ground).

optimisation(min(_)).
optimisation(max(_)).

select_var(leftmost, [Var|Vars], Var, Vars).
select_var(min, [V|Vs], Var, RVars) :-
        find_min(Vs, V, Var),
        delete_eq([V|Vs], Var, RVars).
select_var(max, [V|Vs], Var, RVars) :-
        find_max(Vs, V, Var),
        delete_eq([V|Vs], Var, RVars).
select_var(ff, [V|Vs], Var, RVars) :-
        find_ff(Vs, V, Var),
        delete_eq([V|Vs], Var, RVars).
select_var(ffc, [V|Vs], Var, RVars) :-
        find_ffc(Vs, V, Var),
        delete_eq([V|Vs], Var, RVars).

find_min([], Var, Var).
find_min([V|Vs], CM, Min) :-
        (   min_lt(V, CM) ->
            find_min(Vs, V, Min)
        ;   find_min(Vs, CM, Min)
        ).

find_max([], Var, Var).
find_max([V|Vs], CM, Max) :-
        (   max_gt(V, CM) ->
            find_max(Vs, V, Max)
        ;   find_max(Vs, CM, Max)
        ).

find_ff([], Var, Var).
find_ff([V|Vs], CM, FF) :-
        (   ff_lt(V, CM) ->
            find_ff(Vs, V, FF)
        ;   find_ff(Vs, CM, FF)
        ).

find_ffc([], Var, Var).
find_ffc([V|Vs], Prev, FFC) :-
        (   ffc_lt(V, Prev) ->
            find_ffc(Vs, V, FFC)
        ;   find_ffc(Vs, Prev, FFC)
        ).

ff_lt(X, Y) :-
        (   fd_get(X, DX, _) ->
            domain_num_elements(DX, n(NX))
        ;   NX = 1
        ),
        (   fd_get(Y, DY, _) ->
            domain_num_elements(DY, n(NY))
        ;   NY = 1
        ),
        NX < NY.

ffc_lt(X, Y) :-
        (   fd_get(X, XD, XPs) ->
            domain_num_elements(XD, n(NXD))
        ;   NXD = 1, XPs = []
        ),
        (   fd_get(Y, YD, YPs) ->
            domain_num_elements(YD, n(NYD))
        ;   NYD = 1, YPs = []
        ),
        (   NXD < NYD -> true
        ;   NXD =:= NYD,
            props_number(XPs, NXPs),
            props_number(YPs, NYPs),
            NXPs > NYPs
        ).

min_lt(X,Y) :- bounds(X,LX,_), bounds(Y,LY,_), LX < LY.

max_gt(X,Y) :- bounds(X,_,UX), bounds(Y,_,UY), UX > UY.

bounds(X, L, U) :-
        (   fd_get(X, Dom, _) ->
            domain_infimum(Dom, n(L)),
            domain_supremum(Dom, n(U))
        ;   L = X, U = L
        ).

delete_eq([],_,[]).
delete_eq([X|Xs],Y,List) :-
        (   X == Y -> List = Xs
        ;   List = [X|Tail],
            delete_eq(Xs,Y,Tail)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   contracting/1 -- subject to change

   This can remove additional domain elements from the boundaries.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

contracting(Vs) :-
        must_be(list, Vs),
        maplist(finite_domain, Vs),
        contracting(Vs, fail, Vs).

contracting([], Repeat, Vars) :-
        (   Repeat -> contracting(Vars, fail, Vars)
        ;   true
        ).
contracting([V|Vs], Repeat, Vars) :-
        fd_inf(V, Min),
        (   \+ \+ (V = Min) ->
            fd_sup(V, Max),
            (   \+ \+ (V = Max) ->
                contracting(Vs, Repeat, Vars)
            ;   V #\= Max,
                contracting(Vs, true, Vars)
            )
        ;   V #\= Min,
            contracting(Vs, true, Vars)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   fds_sespsize(Vs, S).

   S is an upper bound on the search space size with respect to finite
   domain variables Vs.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

fds_sespsize(Vs, S) :-
        must_be(list, Vs),
        maplist(fd_variable, Vs),
        fds_sespsize(Vs, n(1), S1),
        bound_portray(S1, S).

fd_size_(V, S) :-
        (   fd_get(V, D, _) ->
            domain_num_elements(D, S)
        ;   S = n(1)
        ).

fds_sespsize([], S, S).
fds_sespsize([V|Vs], S0, S) :-
        fd_size_(V, S1),
        S2 cis S0*S1,
        fds_sespsize(Vs, S2, S).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Optimisation uses destructive assignment to save the computed
   extremum over backtracking. Failure is used to get rid of copies of
   attributed variables that are created in intermediate steps. At
   least that's the intention - it currently doesn't work in SWI:

   %?- X in 0..3, call_residue_vars(labeling([min(X)], [X]), Vs).
   %@ X = 0,
   %@ Vs = [_G6174, _G6177],
   %@ _G6174 in 0..3

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

optimise(Vars, Options, Whats) :-
        Whats = [What|WhatsRest],
        Extremum = extremum(none),
        (   catch(store_extremum(Vars, Options, What, Extremum),
                  time_limit_exceeded,
                  false)
        ;   Extremum = extremum(n(Val)),
            arg(1, What, Expr),
            append(WhatsRest, Options, Options1),
            (   Expr #= Val,
                labeling(Options1, Vars)
            ;   Expr #\= Val,
                optimise(Vars, Options, Whats)
            )
        ).

store_extremum(Vars, Options, What, Extremum) :-
        catch((labeling(Options, Vars), throw(w(What))), w(What1), true),
        functor(What, Direction, _),
        maplist(arg(1), [What,What1], [Expr,Expr1]),
        optimise(Direction, Options, Vars, Expr1, Expr, Extremum).

optimise(Direction, Options, Vars, Expr0, Expr, Extremum) :-
        must_be(ground, Expr0),
        nb_setarg(1, Extremum, n(Expr0)),
        catch((tighten(Direction, Expr, Expr0),
               labeling(Options, Vars),
               throw(v(Expr))), v(Expr1), true),
        optimise(Direction, Options, Vars, Expr1, Expr, Extremum).

tighten(min, E, V) :- E #< V.
tighten(max, E, V) :- E #> V.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% all_different(+Vars)
%
% Vars are pairwise distinct.

all_different(Ls) :-
        must_be(list, Ls),
        all_different(Ls, [], _),
        do_queue.

all_different([], _, _).
all_different([X|Right], Left, State) :-
        (   var(X) ->
            make_propagator(pdifferent(Left,Right,X,State), Prop),
            init_propagator(X, Prop),
            trigger_prop(Prop)
        ;   exclude_fire(Left, Right, X)
        ),
        all_different(Right, [X|Left], State).

%% sum(+Vars, +Rel, +Expr)
%
% The sum of elements of the list Vars is in relation Rel to Expr. For
% example:
%
% ==
% ?- [A,B,C] ins 0..sup, sum([A,B,C], #=, 100).
% A in 0..100,
% A+B+C#=100,
% B in 0..100,
% C in 0..100.
% ==

scalar_supported(#=).
scalar_supported(#\=).

sum(Ls, Op, Value) :-
        must_be(list, Ls),
        maplist(fd_variable, Ls),
        must_be(callable, Op),
        (   scalar_supported(Op),
            vars_plusterm(Ls, 0, Left),
            left_right_linsum_const(Left, Value, Cs, Vs, Const) ->
            scalar_product(Cs, Vs, Op, Const)
        ;   sum(Ls, 0, Op, Value)
        ).

vars_plusterm([], T, T).
vars_plusterm([V|Vs], T0, T) :- vars_plusterm(Vs, T0+V, T).

scalar_product(Cs, Vs, Op, C) :-
        (   Op == (#=)  -> Prop = scalar_product_eq(Cs,Vs,C)
        ;   Op == (#\=) -> Prop = scalar_product_neq(Cs,Vs,C)
        ;   domain_error(scalar_product_relation, Op)
        ),
        propagator_init_trigger(Vs, Prop).

sum([], Sum, Op, Value) :- call(Op, Sum, Value).
sum([X|Xs], Acc, Op, Value) :-
        NAcc #= Acc + X,
        sum(Xs, NAcc, Op, Value).

coeffs_variables_const([], [], [], [], I, I).
coeffs_variables_const([C|Cs], [V|Vs], Cs1, Vs1, I0, I) :-
        (   var(V) ->
            Cs1 = [C|CRest], Vs1 = [V|VRest], I1 = I0
        ;   I1 is I0 + C*V,
            Cs1 = CRest, Vs1 = VRest
        ),
        coeffs_variables_const(Cs, Vs, CRest, VRest, I1, I).

sum_finite_domains([], [], [], [], Inf, Sup, Inf, Sup).
sum_finite_domains([C|Cs], [V|Vs], Infs, Sups, Inf0, Sup0, Inf, Sup) :-
        fd_get(V, _, Inf1, Sup1, _),
        (   Inf1 = n(NInf) ->
            (   C < 0 ->
                Sup2 is Sup0 + C*NInf
            ;   Inf2 is Inf0 + C*NInf
            ),
            Sups = Sups1,
            Infs = Infs1
        ;   (   C < 0 ->
                Sup2 = Sup0,
                Sups = [C*V|Sups1],
                Infs = Infs1
            ;   Inf2 = Inf0,
                Infs = [C*V|Infs1],
                Sups = Sups1
            )
        ),
        (   Sup1 = n(NSup) ->
            (   C < 0 ->
                Inf2 is Inf0 + C*NSup
            ;   Sup2 is Sup0 + C*NSup
            ),
            Sups1 = Sups2,
            Infs1 = Infs2
        ;   (   C < 0 ->
                Inf2 = Inf0,
                Infs1 = [C*V|Infs2],
                Sups1 = Sups2
            ;   Sup2 = Sup0,
                Sups1 = [C*V|Sups2],
                Infs1 = Infs2
            )
        ),
        sum_finite_domains(Cs, Vs, Infs2, Sups2, Inf2, Sup2, Inf, Sup).

remove_dist_upper_lower([], _, _, _).
remove_dist_upper_lower([C|Cs], [V|Vs], D1, D2) :-
        (   fd_get(V, VD, VPs) ->
            (   C < 0 ->
                domain_supremum(VD, n(Sup)),
                L is Sup + D1//C,
                domain_remove_smaller_than(VD, L, VD1),
                domain_infimum(VD1, n(Inf)),
                G is Inf - D2//C,
                domain_remove_greater_than(VD1, G, VD2)
            ;   domain_infimum(VD, n(Inf)),
                G is Inf + D1//C,
                domain_remove_greater_than(VD, G, VD1),
                domain_supremum(VD1, n(Sup)),
                L is Sup - D2//C,
                domain_remove_smaller_than(VD1, L, VD2)
            ),
            fd_put(V, VD2, VPs)
        ;   true
        ),
        remove_dist_upper_lower(Cs, Vs, D1, D2).

remove_dist_upper([], _).
remove_dist_upper([C*V|CVs], D) :-
        (   fd_get(V, VD, VPs) ->
            (   C < 0 ->
                (   domain_supremum(VD, n(Sup)) ->
                    L is Sup + D//C,
                    domain_remove_smaller_than(VD, L, VD1)
                ;   VD1 = VD
                )
            ;   (   domain_infimum(VD, n(Inf)) ->
                    G is Inf + D//C,
                    domain_remove_greater_than(VD, G, VD1)
                ;   VD1 = VD
                )
            ),
            fd_put(V, VD1, VPs)
        ;   true
        ),
        remove_dist_upper(CVs, D).

remove_dist_lower([], _).
remove_dist_lower([C*V|CVs], D) :-
        (   fd_get(V, VD, VPs) ->
            (   C < 0 ->
                (   domain_infimum(VD, n(Inf)) ->
                    G is Inf - D//C,
                    domain_remove_greater_than(VD, G, VD1)
                ;   VD1 = VD
                )
            ;   (   domain_supremum(VD, n(Sup)) ->
                    L is Sup - D//C,
                    domain_remove_smaller_than(VD, L, VD1)
                ;   VD1 = VD
                )
            ),
            fd_put(V, VD1, VPs)
        ;   true
        ),
        remove_dist_lower(CVs, D).

remove_upper([], _).
remove_upper([C*X|CXs], Max) :-
        (   fd_get(X, XD, XPs) ->
            D is Max//C,
            (   C < 0 ->
                domain_remove_smaller_than(XD, D, XD1)
            ;   domain_remove_greater_than(XD, D, XD1)
            ),
            fd_put(X, XD1, XPs)
        ;   true
        ),
        remove_upper(CXs, Max).

remove_lower([], _).
remove_lower([C*X|CXs], Min) :-
        (   fd_get(X, XD, XPs) ->
            D is -Min//C,
            (   C < 0 ->
                domain_remove_greater_than(XD, D, XD1)
            ;   domain_remove_smaller_than(XD, D, XD1)
            ),
            fd_put(X, XD1, XPs)
        ;   true
        ),
        remove_lower(CXs, Min).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Constraint propagation proceeds as follows: Each CLP(FD) variable
   has an attribute that stores its associated domain and constraints.
   Constraints are triggered when the event they are registered for
   occurs (for example: variable is instantiated, bounds change etc.).
   do_queue/0 works off all triggered constraints, possibly triggering
   new ones, until fixpoint.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

% % LIFO queue
% make_queue :- nb_setval('$propagator_queue',[]).

% push_queue(E) :-
%         b_getval('$propagator_queue',Q),
%         b_setval('$propagator_queue',[E|Q]).
% pop_queue(E) :-
%         b_getval('$propagator_queue',[E|Q]),
%         b_setval('$propagator_queue',Q).


% FIFO queue
make_queue :- nb_setval('$clpfd_queue', Q-Q).
push_queue(E) :-
        b_getval('$clpfd_queue', H-[E|T]), b_setval('$clpfd_queue', H-T).
pop_queue(E) :-
        b_getval('$clpfd_queue', H-T),
        nonvar(H), H = [E|NH], b_setval('$clpfd_queue', NH-T).

fetch_propagator(Prop) :-
        pop_queue(P),
        (   arg(2, P, S), S == dead -> fetch_propagator(Prop)
        ;   Prop = P
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Parsing a CLP(FD) expression has two important side-effects: First,
   it constrains the variables occurring in the expression to
   integers. Second, it constrains some of them even more: For
   example, in X/Y and X mod Y, Y is constrained to be #\= 0.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

constrain_to_integer(Var) :-
        (   integer(Var) -> true
        ;   fd_get(Var, D, Ps),
            fd_put(Var, D, Ps)
        ).

power_var_num(P, X, N) :-
        (   var(P) -> X = P, N = 1
        ;   P = Left*Right,
            power_var_num(Left, XL, L),
            power_var_num(Right, XR, R),
            XL == XR,
            X = XL,
            N is L + R
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Given expression E, we obtain the finite domain variable R by
   interpreting a simple committed-choice language that is a list of
   conditions and bodies. In conditions, g(Goal) means literally Goal,
   and m(Match) means that E can be decomposed as stated. The
   variables are to be understood as the result of parsing the
   subexpressions recursively. In the body, g(Goal) means again Goal,
   and p(Propagator) means to attach and trigger once a propagator.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

parse_clpfd(E, R,
            [g(cyclic_term(E)) -> [g(domain_error(clpfd_expression, E))],
             g(var(E))         -> [g(constrain_to_integer(E)), g(E = R)],
             g(integer(E))     -> [g(R = E)],
             m(A+B)            -> [p(pplus(A, B, R))],
             % power_var_num/3 must occur before */2 to be useful
             g(power_var_num(E, V, N)) -> [p(pexp(V, N, R))],
             m(A*B)            -> [p(ptimes(A, B, R))],
             m(A-B)            -> [p(pplus(R,B,A))],
             m(-A)             -> [p(ptimes(-1,A,R))],
             m(max(A,B))       -> [g(A #=< R), g(B #=< R), p(pmax(A, B, R))],
             m(min(A,B))       -> [g(A #>= R), g(B #>= R), p(pmin(A, B, R))],
             m(mod(A,B))       -> [g(B #\= 0), p(pmod(A, B, R))],
             m(abs(A))         -> [g(R #>= 0), p(pabs(A, R))],
             m(A/B)            -> [g(B #\= 0), p(pdiv(A, B, R))],
             m(A^B)            -> [p(pexp(A, B, R))],
             g(true)           -> [g(domain_error(clpfd_expression, E))]
            ]).

% Here, we compile the committed choice language to a single
% predicate, parse_clpfd/2.

make_parse_clpfd(Clauses) :-
        parse_clpfd_clauses(Clauses0),
        maplist(goals_goal, Clauses0, Clauses).

goals_goal(Head :- Goals, Head :- Body) :-
        list_goal(Goals, Body).

parse_clpfd_clauses(Clauses) :-
        parse_clpfd(E, R, Matchers),
        maplist(parse_matcher(E, R), Matchers, Clauses).

parse_matcher(E, R, Matcher, Clause) :-
        Matcher = (Condition0 -> Goals0),
        phrase((parse_condition(Condition0, E, Head),
                parse_goals(Goals0)), Goals),
        Clause = (parse_clpfd(Head, R) :- Goals).

parse_condition(g(Goal), E, E) --> [Goal, !].
parse_condition(m(Match), _, Match0) -->
        { copy_term(Match, Match0) },
        [!],
        { term_variables(Match0, Vs0),
          term_variables(Match, Vs)
        },
        parse_match_variables(Vs0, Vs).

parse_match_variables([], []) --> [].
parse_match_variables([V0|Vs0], [V|Vs]) -->
        [parse_clpfd(V0, V)],
        parse_match_variables(Vs0, Vs).

parse_goals([]) --> [].
parse_goals([G|Gs]) --> parse_goal(G), parse_goals(Gs).

parse_goal(g(Goal)) --> [Goal].
parse_goal(p(Prop)) -->
        [make_propagator(Prop, P)],
        { term_variables(Prop, Vs) },
        parse_init(Vs, P),
        [trigger_once(P)].

parse_init([], _)     --> [].
parse_init([V|Vs], P) --> [init_propagator(V, P)], parse_init(Vs, P).

%?- set_prolog_flag(toplevel_print_options, [portray(true)]),
%   clpfd:parse_clpfd_clauses(Clauses), maplist(portray_clause, Clauses).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_once(Prop) :- trigger_prop(Prop), do_queue.

neq(A, B) :- propagator_init_trigger(pneq(A, B)).

propagator_init_trigger(P) -->
        { term_variables(P, Vs) },
        propagator_init_trigger(Vs, P).

propagator_init_trigger(Vs, P) -->
        [p(Prop)],
        { make_propagator(P, Prop),
          maplist(prop_init(Prop), Vs),
          trigger_once(Prop) }.

propagator_init_trigger(P) :-
        phrase(propagator_init_trigger(P), _).

propagator_init_trigger(Vs, P) :-
        phrase(propagator_init_trigger(Vs, P), _).

prop_init(Prop, V) :-init_propagator(V, Prop).

geq(A, B) :-
        (   fd_get(A, AD, APs) ->
            domain_infimum(AD, AI),
            (   fd_get(B, BD, _) ->
                domain_supremum(BD, BS),
                (   AI cis_geq BS -> true
                ;   propagator_init_trigger(pgeq(A,B))
                )
            ;   domain_remove_smaller_than(AD, B, AD1),
                fd_put(A, AD1, APs),
                do_queue
            )
        ;   fd_get(B, BD, BPs) ->
            domain_remove_greater_than(BD, A, BD1),
            fd_put(B, BD1, BPs),
            do_queue
        ;   A >= B
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Naive parsing of inequalities and disequalities can result in a lot
   of unnecessary work if expressions of non-trivial depth are
   involved: Auxiliary variables are introduced for sub-expressions,
   and propagation proceeds on them as if they were involved in a
   tighter constraint (like equality), whereas eventually only very
   little of the propagated information is actually used. For example,
   only extremal values are of interest in inequalities. Introducing
   auxiliary variables should be avoided when possible, and
   specialised propagators should be used for common constraints.

   We again use a simple committed-choice language for matching
   special cases of constraints. m_c(M,C) means that M matches and C
   holds. d(X, Y) means decomposition, i.e., it is short for
   g(parse_clpfd(X, Y)). r(X, Y) means to rematch with X and Y.

   Two things are important: First, although the actual constraint
   functors (#\=2, #=/2 etc.) are used in the description, they must
   expand to the respective auxiliary predicates (match_expand/2)
   because the actual constraints are subject to goal expansion.
   Second, when specialised constraints (like scalar product) post
   simpler constraints on their own, these simpler versions must be
   handled separately and must occur before.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

match_expand(#>=, clpfd_geq_).
match_expand(#=, clpfd_equal_).
match_expand(#\=, clpfd_neq).

symmetric(#=).
symmetric(#\=).

matches([
         m_c(any(X) #>= any(Y), left_right_linsum_const(X, Y, Cs, Vs, Const)) ->
            [g((   Cs = [1], Vs = [A] -> geq(A, Const)
               ;   Cs = [-1], Vs = [A] -> Const1 is -Const, geq(Const1, A)
               ;   Cs = [1,1], Vs = [A,B] -> A+B #= S, geq(S, Const)
               ;   Cs = [1,-1], Vs = [A,B] ->
                   (   Const =:= 0 -> geq(A, B)
                   ;   C1 is -Const,
                       propagator_init_trigger(x_leq_y_plus_c(B, A, C1))
                   )
               ;   Cs = [-1,1], Vs = [A,B] ->
                   (   Const =:= 0 -> geq(B, A)
                   ;   C1 is -Const,
                       propagator_init_trigger(x_leq_y_plus_c(A, B, C1))
                   )
               ;   Cs = [-1,-1], Vs = [A,B] ->
                   A+B #= S, Const1 is -Const, geq(Const1, S)
               ;   scalar_product([1|Cs], [S|Vs], #=, Const), geq(0, S)
               ))],
         m(any(X) - any(Y) #>= integer(C))     -> [d(X, X1), d(Y, Y1), g(C1 is -C), p(x_leq_y_plus_c(Y1, X1, C1))],
         m(integer(X) #>= any(Z) + integer(A)) -> [g(C is X - A), r(C, Z)],
         m(abs(any(X)-any(Y)) #>= integer(I))  -> [d(X, X1), d(Y, Y1), p(absdiff_geq(X1, Y1, I))],
         m(abs(any(X)) #>= integer(I))         -> [d(X, RX), g((I>0 -> I1 is -I, RX in inf..I1 \/ I..sup; true))],
         m(integer(I) #>= abs(any(X)))         -> [d(X, RX), g(I>=0), g(I1 is -I), g(RX in I1..I)],
         m(any(X) #>= any(Y))                  -> [d(X, RX), d(Y, RY), g(geq(RX, RY))],

         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

         m(var(X) #= var(Y))        -> [g(constrain_to_integer(X)), g(X=Y)],
         m(var(X) #= var(Y)+var(Z)) -> [p(pplus(Y,Z,X))],
         m(var(X) #= var(Y)-var(Z)) -> [p(pplus(X,Z,Y))],
         m(var(X) #= var(Y)*var(Z)) -> [p(ptimes(Y,Z,X))],
         m(var(X) #= -var(Z))       -> [p(ptimes(-1, Z, X))],
         m_c(any(X) #= any(Y), left_right_linsum_const(X, Y, Cs, Vs, S)) ->
            [g((   Cs = [] -> S =:= 0
               ;   Cs = [C|CsRest],
                   gcd(CsRest, C, GCD),
                   S mod GCD =:= 0,
                   scalar_product(Cs, Vs, #=, S)
               ))],
         m(var(X) #= any(Y))       -> [d(Y,X)],
         m(any(X) #= any(Y))       -> [d(X, RX), d(Y, RX)],

         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
         %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

         m(var(X) #\= integer(Y))             -> [g(neq_num(X, Y))],
         m(var(X) #\= var(Y))                 -> [g(neq(X,Y))],
         m(var(X) #\= var(Y) + var(Z))        -> [p(x_neq_y_plus_z(X, Y, Z))],
         m(var(X) #\= var(Y) - var(Z))        -> [p(x_neq_y_plus_z(Y, X, Z))],
         m(var(X) #\= var(Y)*var(Z))          -> [p(ptimes(Y,Z,P)), g(neq(X,P))],
         m(integer(X) #\= abs(any(Y)-any(Z))) -> [d(Y, Y1), d(Z, Z1), p(absdiff_neq(Y1, Z1, X))],
         m_c(any(X) #\= any(Y), left_right_linsum_const(X, Y, Cs, Vs, S)) ->
            [g(scalar_product(Cs, Vs, #\=, S))],
         m(any(X) #\= any(Y) + any(Z))        -> [d(X, X1), d(Y, Y1), d(Z, Z1), p(x_neq_y_plus_z(X1, Y1, Z1))],
         m(any(X) #\= any(Y) - any(Z))        -> [d(X, X1), d(Y, Y1), d(Z, Z1), p(x_neq_y_plus_z(Y1, X1, Z1))],
         m(any(X) #\= any(Y)) -> [d(X, RX), d(Y, RY), g(neq(RX, RY))]
        ]).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   We again compile the committed-choice matching language to the
   intended auxiliary predicates. We now must take care not to
   unintentionally unify a variable with a complex term.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

make_matches(Clauses) :-
        matches(Ms),
        findall(F, (member(M->_, Ms), arg(1, M, M1), functor(M1, F, _)), Fs0),
        sort(Fs0, Fs),
        maplist(prevent_cyclic_argument, Fs, PrevCyclicClauses),
        phrase(matchers(Ms), Clauses0),
        maplist(goals_goal, Clauses0, MatcherClauses),
        append(PrevCyclicClauses, MatcherClauses, Clauses1),
        sort_by_predicate(Clauses1, Clauses).

sort_by_predicate(Clauses, ByPred) :-
        map_list_to_pairs(predname, Clauses, Keyed),
        keysort(Keyed, KeyedByPred),
        pairs_values(KeyedByPred, ByPred).

predname((H:-_), Key)   :- !, predname(H, Key).
predname(M:H, M:Key)    :- !, predname(H, Key).
predname(H, Name/Arity) :- !, functor(H, Name, Arity).

prevent_cyclic_argument(F0, Clause) :-
        match_expand(F0, F),
        Head =.. [F,X,Y],
        Clause = (Head :- (   cyclic_term(X) ->
                              domain_error(clpfd_expression, X)
                          ;   cyclic_term(Y) ->
                              domain_error(clpfd_expression, Y)
                          ;   false
                          )).

matchers([]) --> [].
matchers([Condition->Goals|Ms]) -->
        matcher(Condition, Goals),
        matchers(Ms).

matcher(m(M), Gs) --> matcher(m_c(M,true), Gs).
matcher(m_c(Matcher,Cond), Gs) -->
        [Head :- Goals0],
        { Matcher =.. [F,A,B],
          match_expand(F, Expand),
          Head =.. [Expand,X,Y],
          phrase((match(A, X), match(B, Y)), Goals0, [Cond,!|Goals1]),
          phrase(match_goals(Gs, Expand), Goals1) },
        (   { symmetric(F), \+ (subsumes_chk(A, B), subsumes_chk(B, A)) } ->
            { Head1 =.. [Expand,Y,X] },
            [Head1 :- Goals0]
        ;   []
        ).

match(any(A), T)     --> [A = T].
match(var(V), T)     --> [v_or_i(T), V = T].
match(integer(I), T) --> [integer(T), I = T].
match(-X, T)         --> [nonvar(T), T = -A], match(X, A).
match(abs(X), T)     --> [nonvar(T), T = abs(A)], match(X, A).
match(X+Y, T)        --> [nonvar(T), T = A + B], match(X, A), match(Y, B).
match(X-Y, T)        --> [nonvar(T), T = A - B], match(X, A), match(Y, B).
match(X*Y, T)        --> [nonvar(T), T = A * B], match(X, A), match(Y, B).

match_goals([], _)     --> [].
match_goals([G|Gs], F) --> match_goal(G, F), match_goals(Gs, F).

match_goal(r(X,Y), F)  --> { G =.. [F,X,Y] }, [G].
match_goal(d(X,Y), _)  --> [parse_clpfd(X, Y)].
match_goal(g(Goal), _) --> [Goal].
match_goal(p(Prop), _) -->
        [make_propagator(Prop, P)],
        { term_variables(Prop, Vs) },
        parse_init(Vs, P),
        [trigger_once(P)].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%% ?X #>= ?Y
%
% X is greater than or equal to Y.

X #>= Y :- clpfd_geq(X, Y).

clpfd_geq(X, Y) :- clpfd_geq_(X, Y), reinforce(X), reinforce(Y).

%% ?X #=< ?Y
%
% X is less than or equal to Y.

X #=< Y :- Y #>= X.

%% ?X #= ?Y
%
% X equals Y.

X #= Y :- clpfd_equal(X, Y).

clpfd_equal(X, Y) :- clpfd_equal_(X, Y), reinforce(X).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Conditions under which an equality can be compiled to built-in
   arithmetic. Their order is significant.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

expr_conds(E, E)                 --> { var(E) }, !, [integer(E)].
expr_conds(E, E)                 --> { integer(E) }, !, [].
expr_conds(-E0, -E)              --> expr_conds(E0, E).
expr_conds(abs(E0), abs(E))      --> expr_conds(E0, E).
expr_conds(A0+B0, A+B)           --> expr_conds(A0, A), expr_conds(B0, B).
expr_conds(A0*B0, A*B)           --> expr_conds(A0, A), expr_conds(B0, B).
expr_conds(A0-B0, A-B)           --> expr_conds(A0, A), expr_conds(B0, B).
expr_conds(A0/B0, A//B)          --> % "/" becomes "//"
        expr_conds(A0, A), expr_conds(B0, B),
        [B =\= 0].
expr_conds(min(A0,B0), min(A,B)) --> expr_conds(A0, A), expr_conds(B0, B).
expr_conds(max(A0,B0), max(A,B)) --> expr_conds(A0, A), expr_conds(B0, B).
expr_conds(A0 mod B0, A mod B)   -->
        expr_conds(A0, A), expr_conds(B0, B),
        [B =\= 0].
expr_conds(A0^B0, A^B)           -->
        expr_conds(A0, A), expr_conds(B0, B),
        [(B >= 0 ; A =:= -1)].

:- multifile
        user:goal_expansion/2.
:- dynamic
        user:goal_expansion/2.

user:goal_expansion(X0 #= Y0, Equal) :-
        \+ current_prolog_flag(clpfd_goal_expansion, false),
        phrase(clpfd:expr_conds(X0, X), CsX),
        phrase(clpfd:expr_conds(Y0, Y), CsY),
        clpfd:list_goal(CsX, CondX),
        clpfd:list_goal(CsY, CondY),
        Equal = (   (CondX,CondY) -> X =:= Y
                ;   CondX ->
                    (   var(Y) -> Y is X
                    ;   T is X, clpfd:clpfd_equal(T, Y0)
                    )
                ;   CondY ->
                    (   var(X) -> X is Y
                    ;   T is Y, clpfd:clpfd_equal(X0, T)
                    )
                ;   clpfd:clpfd_equal(X0, Y0)
                ).
user:goal_expansion(X0 #>= Y0, Geq) :-
        \+ current_prolog_flag(clpfd_goal_expansion, false),
        phrase(clpfd:expr_conds(X0, X), CsX),
        phrase(clpfd:expr_conds(Y0, Y), CsY),
        clpfd:list_goal(CsX, CondX),
        clpfd:list_goal(CsY, CondY),
        Geq = (   (CondX,CondY) -> X >= Y
              ;   CondX -> T is X, clpfd:clpfd_geq(T, Y0)
              ;   CondY -> T is Y, clpfd:clpfd_geq(X0, T)
              ;   clpfd:clpfd_geq(X0, Y0)
              ).
user:goal_expansion(X #=< Y,  Leq) :- user:goal_expansion(Y #>= X, Leq).
user:goal_expansion(X #> Y, Gt)    :- user:goal_expansion(X #>= Y+1, Gt).
user:goal_expansion(X #< Y, Lt)    :- user:goal_expansion(Y #> X, Lt).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

linsum(X, S, S)    --> { var(X) }, !, [vn(X,1)].
linsum(I, S0, S)   --> { integer(I), !, S is S0 + I }.
linsum(-A, S0, S)  --> mulsum(A, -1, S0, S).
linsum(N*A, S0, S) --> { integer(N) }, !, mulsum(A, N, S0, S).
linsum(A*N, S0, S) --> { integer(N) }, !, mulsum(A, N, S0, S).
linsum(A+B, S0, S) --> linsum(A, S0, S1), linsum(B, S1, S).
linsum(A-B, S0, S) --> linsum(A, S0, S1), mulsum(B, -1, S1, S).

mulsum(A, M, S0, S) -->
        { phrase(linsum(A, 0, CA), As), S is S0 + M*CA },
        lin_mul(As, M).

lin_mul([], _)             --> [].
lin_mul([vn(X,N0)|VNs], M) --> { N is N0*M }, [vn(X,N)], lin_mul(VNs, M).

v_or_i(V) :- var(V), !.
v_or_i(I) :- integer(I).

left_right_linsum_const(Left, Right, Cs, Vs, Const) :-
        phrase(linsum(Left, 0, CL), Lefts0, Rights),
        phrase(linsum(Right, 0, CR), Rights0),
        maplist(linterm_negate, Rights0, Rights),
        msort(Lefts0, Lefts),
        Lefts = [vn(First,N)|LeftsRest],
        vns_coeffs_variables(LeftsRest, N, First, Cs0, Vs0),
        filter_linsum(Cs0, Vs0, Cs, Vs),
        Const is CR - CL.
        %format("linear sum: ~w ~w ~w\n", [Cs,Vs,Const]).

linterm_negate(vn(V,N0), vn(V,N)) :- N is -N0.

vns_coeffs_variables([], N, V, [N], [V]).
vns_coeffs_variables([vn(V,N)|VNs], N0, V0, Ns, Vs) :-
        (   V == V0 ->
            N1 is N0 + N,
            vns_coeffs_variables(VNs, N1, V0, Ns, Vs)
        ;   Ns = [N0|NRest],
            Vs = [V0|VRest],
            vns_coeffs_variables(VNs, N, V, NRest, VRest)
        ).

filter_linsum([], [], [], []).
filter_linsum([C0|Cs0], [V0|Vs0], Cs, Vs) :-
        (   C0 =:= 0 ->
            constrain_to_integer(V0),
            filter_linsum(Cs0, Vs0, Cs, Vs)
        ;   Cs = [C0|Cs1], Vs = [V0|Vs1],
            filter_linsum(Cs0, Vs0, Cs1, Vs1)
        ).

gcd([], G, G).
gcd([N|Ns], G0, G) :-
        gcd_(N, G0, G1),
        gcd(Ns, G1, G).

gcd_(A, B, G) :-
        (   B =:= 0 -> G = A
        ;   R is A mod B,
            gcd_(B, R, G)
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   k-th root of N, if N is a k-th power.

   TODO: Replace this when the GMP function becomes available.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

integer_kth_root(N, K, R) :-
        (   K mod 2 =:= 0 ->
            N >= 0
        ;   true
        ),
        (   N < 0 ->
            K mod 2 =:= 1,
            integer_kroot(N, 0, N, K, R)
        ;   integer_kroot(0, N, N, K, R)
        ).

integer_kroot(L, U, N, K, R) :-
        (   L =:= U -> N =:= L^K, R = L
        ;   L + 1 =:= U ->
            (   L^K =:= N -> R = L
            ;   U^K =:= N -> R = U
            ;   fail
            )
        ;   Mid is (L + U)//2,
            (   Mid^K > N ->
                integer_kroot(L, Mid, N, K, R)
            ;   integer_kroot(Mid, U, N, K, R)
            )
        ).


%% ?X #\= ?Y
%
% X is not Y.

X #\= Y :- clpfd_neq(X, Y), do_queue.

% X #\= Y + Z

x_neq_y_plus_z(X, Y, Z) :-
        propagator_init_trigger(x_neq_y_plus_z(X,Y,Z)).

% X is distinct from the number N. This is used internally, and does
% not reinforce other constraints.

neq_num(X, N) :-
        (   fd_get(X, XD, XPs) ->
            domain_remove(XD, N, XD1),
            fd_put(X, XD1, XPs)
        ;   X =\= N
        ).

%% ?X #> ?Y
%
% X is greater than Y.

X #> Y  :- X #>= Y + 1.

%% #<(?X, ?Y)
%
% X is less than Y. In addition to its regular use in problems that
% require it, this constraint can also be useful to eliminate
% uninteresting symmetries from a problem. For example, all possible
% matches between pairs built from four players in total:
%
% ==
% ?- Vs = [A,B,C,D], Vs ins 1..4, all_different(Vs), A #< B, C #< D, A #< C,
%    findall(pair(A,B)-pair(C,D), label(Vs), Ms).
% Ms = [pair(1, 2)-pair(3, 4), pair(1, 3)-pair(2, 4), pair(1, 4)-pair(2, 3)]
% ==

X #< Y  :- Y #> X.

%% #\ +Q
%
% The reifiable constraint Q does _not_ hold. For example, to obtain
% the complement of a domain:
%
% ==
% ?- #\ X in -3..0\/10..80.
% X in inf.. -4\/1..9\/81..sup.
% ==

#\ Q       :- reify(Q, 0), do_queue.

%% ?P #<==> ?Q
%
% P and Q are equivalent. For example:
%
% ==
% ?- X #= 4 #<==> B, X #\= 4.
% B = 0,
% X in inf..3\/5..sup.
% ==

L #<==> R  :- reify(L, B), reify(R, B), do_queue.

%% ?P #==> ?Q
%
% P implies Q.

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Implication is special in that created auxiliary constraints can be
   retracted when the implication becomes entailed, for example:

   %?- X + 1 #= Y #==> Z, Z #= 1.
   %@ Z = 1,
   %@ X in inf..sup,
   %@ Y in inf..sup.

   We cannot use propagator_init_trigger/1 here because the states of
   auxiliary propagators are themselves part of the propagator.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

L #==> R   :-
        phrase((reify(L, BL),reify(R, BR)), Ps),
        propagator_init_trigger([BL,BR], pimpl(BL,BR,Ps)).

%% ?P #<== ?Q
%
% Q implies P.

L #<== R   :- R #==> L.

%% ?P #/\ ?Q
%
% P and Q hold.

L #/\ R    :- reify(L, 1), reify(R, 1), do_queue.

%% ?P #\/ ?Q
%
% P or Q holds. For example, the sum of natural numbers below 1000
% that are multiples of 3 or 5:
%
% ==
% ?- findall(N, (N mod 3 #= 0 #\/ N mod 5 #= 0, N in 0..999, indomain(N)), Ns), sum(Ns, #=, Sum).
% Ns = [0, 3, 5, 6, 9, 10, 12, 15, 18|...],
% Sum = 233168.
% ==

L #\/ R :-
        reify(L, X, Ps1),
        reify(R, Y, Ps2),
        propagator_init_trigger([X,Y], reified_or(X,Ps1,Y,Ps2,1)).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   A constraint that is being reified need not hold. Therefore, in
   X/Y, Y can as well be 0, for example. Note that it is OK to
   constrain the *result* of an expression (which does not appear
   explicitly in the expression and is not visible to the outside),
   but not the operands, except for requiring that they be integers.

   In contrast to parse_clpfd/2, the result of an expression can now
   also be undefined, in which case the constraint cannot hold.
   Therefore, the committed-choice language is extended by an element
   d(D) that states D is 1 iff all subexpressions are defined. a(V)
   means that V is an auxiliary variable that was introduced while
   parsing a compound expression. a(X,V) means V is auxiliary unless
   it is ==/2 X, and a(X,Y,V) means V is auxiliary unless it is ==/2 X
   or Y. l(L) means the literal L occurs in the described list.

   When a constraint becomes entailed or subexpressions become
   undefined, created auxiliary constraints are killed, and the
   "clpfd" attribute is removed from auxiliary variables.

   For (/)/2 and mod/2, we create a skeleton propagator and remember
   it as an auxiliary constraint. The corresponding reified
   propagators can use the skeleton when the constraint is defined.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

parse_reified(E, R, D,
              [g(cyclic_term(E)) -> [g(domain_error(clpfd_expression, E))],
               g(var(E))     -> [g(constrain_to_integer(E)), g(R = E), g(D=1)],
               g(integer(E)) -> [g(R=E), g(D=1)],
               m(A+B)        -> [d(D), p(pplus(A,B,R)), a(A,B,R)],
               m(A*B)        -> [d(D), p(ptimes(A,B,R)), a(A,B,R)],
               m(A-B)        -> [d(D), p(pplus(R,B,A)), a(A,B,R)],
               m(-A)         -> [d(D), p(ptimes(-1,A,R)), a(R)],
               m(max(A,B))   -> [d(D), p(pgeq(R, A)), p(pgeq(R, B)), p(pmax(A,B,R)), a(A,B,R)],
               m(min(A,B))   -> [d(D), p(pgeq(A, R)), p(pgeq(B, R)), p(pmin(A,B,R)), a(A,B,R)],
               m(A mod B)    ->
                  [d(D1), l(p(P)), g(make_propagator(pmod(X,Y,Z), P)),
                   p([A,B,D2,R], reified_mod(A,B,D2,[X,Y,Z]-P,R)),
                   p(reified_and(D1,[],D2,[],D)), a(D2), a(A,B,R)],
               m(abs(A))     -> [g(R#>=0), d(D), p(pabs(A, R)), a(A,R)],
               m(A/B)        ->
                  [d(D1), l(p(P)), g(make_propagator(pdiv(X,Y,Z), P)),
                   p([A,B,D2,R], reified_div(A,B,D2,[X,Y,Z]-P,R)),
                   p(reified_and(D1,[],D2,[],D)), a(D2), a(A,B,R)],
               m(A^B)        -> [d(D), p(pexp(A,B,R)), a(A,B,R)],
               g(true)       -> [g(domain_error(clpfd_expression, E))]]
             ).

% Again, we compile this to a predicate, parse_reified_clpfd//3. This
% time, it is a DCG that describes the list of auxiliary variables and
% propagators for the given expression, in addition to relating it to
% its reified (Boolean) finite domain variable and its Boolean
% definedness.

make_parse_reified(Clauses) :-
        parse_reified_clauses(Clauses0),
        maplist(goals_goal_dcg, Clauses0, Clauses).

goals_goal_dcg(Head --> Goals, Clause) :-
        list_goal(Goals, Body),
        expand_term(Head --> Body, Clause).

parse_reified_clauses(Clauses) :-
        parse_reified(E, R, D, Matchers),
        maplist(parse_reified(E, R, D), Matchers, Clauses).

parse_reified(E, R, D, Matcher, Clause) :-
        Matcher = (Condition0 -> Goals0),
        phrase((reified_condition(Condition0, E, Head, Ds),
                reified_goals(Goals0, Ds)), Goals, [a(D)]),
        Clause = (parse_reified_clpfd(Head, R, D) --> Goals).

reified_condition(g(Goal), E, E, []) --> [{Goal}, !].
reified_condition(m(Match), _, Match0, Ds) -->
        { copy_term(Match, Match0) },
        [!],
        { term_variables(Match0, Vs0),
          term_variables(Match, Vs)
        },
        reified_variables(Vs0, Vs, Ds).

reified_variables([], [], []) --> [].
reified_variables([V0|Vs0], [V|Vs], [D|Ds]) -->
        [parse_reified_clpfd(V0, V, D)],
        reified_variables(Vs0, Vs, Ds).

reified_goals([], _) --> [].
reified_goals([G|Gs], Ds) --> reified_goal(G, Ds), reified_goals(Gs, Ds).

reified_goal(d(D), Ds) -->
        (   { Ds = [X] } -> [{D=X}]
        ;   { Ds = [X,Y] } ->
            { phrase(reified_goal(p(reified_and(X,[],Y,[],D)), _), Gs),
              list_goal(Gs, Goal) },
            [( {X==1, Y==1} -> {D = 1} ; Goal )]
        ;   { domain_error(one_or_two_element_list, Ds) }
        ).
reified_goal(g(Goal), _) --> [{Goal}].
reified_goal(p(Vs, Prop), _) -->
        [{make_propagator(Prop, P)}],
        parse_init_dcg(Vs, P),
        [{trigger_once(P)}],
        [( { arg(2, P, S), S == dead } -> [] ; [p(P)])].
reified_goal(p(Prop), Ds) -->
        { term_variables(Prop, Vs) },
        reified_goal(p(Vs,Prop), Ds).
reified_goal(a(V), _)     --> [a(V)].
reified_goal(a(X,V), _)   --> [a(X,V)].
reified_goal(a(X,Y,V), _) --> [a(X,Y,V)].
reified_goal(l(L), _)     --> [[L]].

parse_init_dcg([], _)     --> [].
parse_init_dcg([V|Vs], P) --> [{init_propagator(V, P)}], parse_init_dcg(Vs, P).

%?- set_prolog_flag(toplevel_print_options, [portray(true)]),
%   clpfd:parse_reified_clauses(Cs), maplist(portray_clause, Cs).

reify(E, B) :- reify(E, B, _).

reify(Expr, B, Ps) :- phrase(reify(Expr, B), Ps).

reify(E, B) --> { B in 0..1 }, reify_(E, B).

reify_(E, _) -->
        { cyclic_term(E), !, domain_error(clpfd_reifiable_expression, E) }.
reify_(E, B) --> { var(E), !, E = B }.
reify_(E, B) --> { integer(E), !, E = B }.
reify_(V in Drep, B) --> !,
        { drep_to_domain(Drep, Dom), fd_variable(V) },
        propagator_init_trigger(reified_in(V,Dom,B)),
        a(B).
reify_(finite_domain(V), B) --> !,
        { fd_variable(V) },
        propagator_init_trigger(reified_fd(V,B)),
        a(B).
reify_(L #>= R, B) --> !,
        { phrase((parse_reified_clpfd(L, LR, LD),
                  parse_reified_clpfd(R, RR, RD)), Ps) },
	list(Ps),
        propagator_init_trigger([LD,LR,RD,RR,B], reified_geq(LD,LR,RD,RR,Ps,B)),
        a(B).
reify_(L #> R, B)  --> !, reify_(L #>= (R+1), B).
reify_(L #=< R, B) --> !, reify_(R #>= L, B).
reify_(L #< R, B)  --> !, reify_(R #>= (L+1), B).
reify_(L #= R, B)  --> !,
        { phrase((parse_reified_clpfd(L, LR, LD),
                  parse_reified_clpfd(R, RR, RD)), Ps) },
        list(Ps),
        propagator_init_trigger([LD,LR,RD,RR,B], reified_eq(LD,LR,RD,RR,Ps,B)),
        a(B).
reify_(L #\= R, B) --> !,
        { phrase((parse_reified_clpfd(L, LR, LD),
                  parse_reified_clpfd(R, RR, RD)), Ps) },
        list(Ps),
        propagator_init_trigger([LD,LR,RD,RR,B], reified_neq(LD,LR,RD,RR,Ps,B)),
        a(B).
reify_(L #==> R, B)  --> !, reify_((#\ L) #\/ R, B).
reify_(L #<== R, B)  --> !, reify_(R #==> L, B).
reify_(L #<==> R, B) --> !, reify_((L #==> R) #/\ (R #==> L), B).
reify_(L #/\ R, B)   --> !,
        { reify(L, LR, Ps1),
          reify(R, RR, Ps2) },
        list(Ps1), list(Ps2),
        propagator_init_trigger([LR,RR,B], reified_and(LR,Ps1,RR,Ps2,B)),
        a(LR, RR, B).
reify_(L #\/ R, B) --> !,
        { reify(L, LR, Ps1),
          reify(R, RR, Ps2) },
        list(Ps1), list(Ps2),
        propagator_init_trigger([LR,RR,B], reified_or(LR,Ps1,RR,Ps2,B)),
        a(LR, RR, B).
reify_(#\ Q, B) --> !,
        reify(Q, QR),
        propagator_init_trigger(reified_not(QR,B)),
        a(B).
reify_(E, _) --> !, { domain_error(clpfd_reifiable_expression, E) }.

list([]) --> [].
list([H|T]) --> [H], list(T).

a(X,Y,B) -->
        (   { nonvar(X) } -> a(Y, B)
        ;   { nonvar(Y) } -> a(X, B)
        ;   [a(X,Y,B)]
        ).

a(X, B) -->
        (   { var(X) } -> [a(X, B)]
        ;   a(B)
        ).

a(B) -->
        (   { var(B) } -> [a(B)]
        ;   []
        ).

% Match variables to created skeleton.

skeleton(Vs, Vs-Prop) :-
        maplist(prop_init(Prop), Vs),
        trigger_once(Prop).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   A drep is a user-accessible and visible domain representation. N,
   N..M, and D1 \/ D2 are dreps, if D1 and D2 are dreps.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

is_drep(V)      :- var(V), !, instantiation_error(V).
is_drep(N)      :- integer(N), !.
is_drep(N..M)   :- !, drep_bound(N), drep_bound(M), N \== sup, M \== inf.
is_drep(D1\/D2) :- !, is_drep(D1), is_drep(D2).

drep_bound(V)   :- var(V), !, instantiation_error(V).
drep_bound(sup) :- !. % should infinities be accessible?
drep_bound(inf) :- !.
drep_bound(I)   :- integer(I), !.

drep_to_intervals(I)        --> { integer(I) }, !, [n(I)-n(I)].
drep_to_intervals(N..M)     -->
        (   { defaulty_to_bound(N, N1), defaulty_to_bound(M, M1),
              N1 cis_leq M1} -> [N1-M1]
        ;   []
        ).
drep_to_intervals(D1 \/ D2) -->
        drep_to_intervals(D1), drep_to_intervals(D2).

drep_to_domain(DR, D) :-
        (   is_drep(DR) -> true
        ;   domain_error(clpfd_domain, DR)
        ),
        phrase(drep_to_intervals(DR), Is0),
        merge_intervals(Is0, Is1),
        intervals_to_domain(Is1, D).

merge_intervals(Is0, Is) :-
        keysort(Is0, Is1),
        merge_overlapping(Is1, Is).

merge_overlapping([], []).
merge_overlapping([A-B0|ABs0], [A-B|ABs]) :-
        merge_remaining(ABs0, B0, B, Rest),
        merge_overlapping(Rest, ABs).

merge_remaining([], B, B, []).
merge_remaining([N-M|NMs], B0, B, Rest) :-
        Next cis B0 + n(1),
        (   N cis_gt Next -> B = B0, Rest = [N-M|NMs]
        ;   B1 cis max(B0,M),
            merge_remaining(NMs, B1, B, Rest)
        ).

domain(V, Dom) :-
        (   fd_get(V, Dom0, VPs) ->
            domains_intersection(Dom, Dom0, Dom1),
            %format("intersected\n: ~w\n ~w\n==> ~w\n\n", [Dom,Dom0,Dom1]),
            fd_put(V, Dom1, VPs),
            do_queue,
            reinforce(V)
        ;   domain_contains(Dom, V)
        ).

domains([], _).
domains([V|Vs], D) :- domain(V, D), domains(Vs, D).

props_number(fd_props(Gs,Bs,Os), N) :-
        length(Gs, N1),
        length(Bs, N2),
        length(Os, N3),
        N is N1 + N2 + N3.

fd_get(X, Dom, Ps) :-
        (   get_attr(X, clpfd, Attr) -> Attr = clpfd_attr(_,_,_,Dom,Ps)
        ;   var(X) -> default_domain(Dom), Ps = fd_props([],[],[])
        ).

fd_get(X, Dom, Inf, Sup, Ps) :-
        fd_get(X, Dom, Ps),
        domain_infimum(Dom, Inf),
        domain_supremum(Dom, Sup).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   By default, propagation always terminates. Currently, this is
   ensured by allowing the left and right boundaries, as well as the
   distance between the smallest and largest number occurring in the
   domain representation to be changed at most once after a constraint
   is posted, unless the domain is bounded. Set the experimental
   Prolog flag 'clpfd_propagation' to 'full' to make the solver
   propagate as much as possible. This can make queries
   non-terminating, like: X #> abs(X), or: X #> Y, Y #> X, X #> 0.
   Importantly, it can also make labeling non-terminating, as in:

   ?- B #==> X #> abs(X), indomain(B).
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

fd_put(X, Dom, Ps) :-
        (   current_prolog_flag(clpfd_propagation, full) ->
            put_full(X, Dom, Ps)
        ;   put_terminating(X, Dom, Ps)
        ).

put_terminating(X, Dom, Ps) :-
        Dom \== empty,
        (   Dom = from_to(F, F) -> F = n(X)
        ;   (   get_attr(X, clpfd, Attr) ->
                Attr = clpfd_attr(Left,Right,Spread,OldDom, _OldPs),
                put_attr(X, clpfd, clpfd_attr(Left,Right,Spread,Dom,Ps)),
                (   OldDom == Dom -> true
                ;   (   Left == (.) -> Bounded = yes
                    ;   domain_infimum(Dom, Inf), domain_supremum(Dom, Sup),
                        (   Inf = n(_), Sup = n(_) ->
                            Bounded = yes
                        ;   Bounded = no
                        )
                    ),
                    (   Bounded == yes ->
                        put_attr(X, clpfd, clpfd_attr(.,.,.,Dom,Ps)),
                        trigger_props(Ps, X, OldDom, Dom)
                    ;   % infinite domain; consider border and spread changes
                        domain_infimum(OldDom, OldInf),
                        (   Inf == OldInf -> LeftP = Left
                        ;   LeftP = yes
                        ),
                        domain_supremum(OldDom, OldSup),
                        (   Sup == OldSup -> RightP = Right
                        ;   RightP = yes
                        ),
                        domain_spread(OldDom, OldSpread),
                        domain_spread(Dom, NewSpread),
                        (   NewSpread == OldSpread -> SpreadP = Spread
                        ;   SpreadP = yes
                        ),
                        put_attr(X, clpfd, clpfd_attr(LeftP,RightP,SpreadP,Dom,Ps)),
                        (   RightP == yes, Right = yes -> true
                        ;   LeftP == yes, Left = yes -> true
                        ;   SpreadP == yes, Spread = yes -> true
                        ;   trigger_props(Ps, X, OldDom, Dom)
                        )
                    )
                )
            ;   var(X) ->
                put_attr(X, clpfd, clpfd_attr(no,no,no,Dom, Ps))
            ;   true
            )
        ).

domain_spread(Dom, Spread) :-
        domain_smallest_finite(Dom, S),
        domain_largest_finite(Dom, L),
        Spread cis L - S.

smallest_finite(inf, Y, Y).
smallest_finite(n(N), _, n(N)).

domain_smallest_finite(from_to(F,T), S)   :- smallest_finite(F, T, S).
domain_smallest_finite(split(_, L, _), S) :- domain_smallest_finite(L, S).

largest_finite(sup, Y, Y).
largest_finite(n(N), _, n(N)).

domain_largest_finite(from_to(F,T), L)   :- largest_finite(T, F, L).
domain_largest_finite(split(_, _, R), L) :- domain_largest_finite(R, L).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   With terminating propagation, all relevant constraints get a
   propagation opportunity whenever a new constraint is posted.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

reinforce(X) :-
        (   current_prolog_flag(clpfd_propagation, full) ->
            % full propagation propagates everything in any case
            true
        ;   term_variables(X, Vs),
            maplist(reinforce_, Vs),
            do_queue
        ).

collect_variables(X, Vs0, Vs) :-
        (   fd_get(X, _, Ps) ->
            term_variables(Ps, Vs1),
            %all_collect(Vs1, [X|Vs0], Vs)
            Vs = [X|Vs1]
        ;   Vs = Vs0
        ).

all_collect([], Vs, Vs).
all_collect([X|Xs], Vs0, Vs) :-
        (   member(V, Vs0), X == V -> all_collect(Xs, Vs0, Vs)
        ;   collect_variables(X, Vs0, Vs1),
            all_collect(Xs, Vs1, Vs)
        ).

reinforce_(X) :-
        (   fd_var(X), fd_get(X, Dom, Ps) ->
            put_full(X, Dom, Ps)
        ;   true
        ).

put_full(X, Dom, Ps) :-
        Dom \== empty,
        (   Dom = from_to(F, F) -> F = n(X)
        ;   (   get_attr(X, clpfd, Attr) ->
                Attr = clpfd_attr(_,_,_,OldDom, _OldPs),
                put_attr(X, clpfd, clpfd_attr(no,no,no,Dom, Ps)),
                %format("putting dom: ~w\n", [Dom]),
                (   OldDom == Dom -> true
                ;   trigger_props(Ps, X, OldDom, Dom)
                )
            ;   var(X) -> %format('\t~w in ~w .. ~w\n',[X,L,U]),
                put_attr(X, clpfd, clpfd_attr(no,no,no,Dom, Ps))
            ;   true
            )
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   A propagator is a term of the form propagator(C, State), where C
   represents a constraint, and State is a free variable that can be
   used to destructively change the state of the propagator via
   attributes. This can be used to avoid redundant invocation of the
   same propagator, or to disable the propagator.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

make_propagator(C, propagator(C, _)).

trigger_props(fd_props(Gs,Bs,Os), X, D0, D) :-
        trigger_props_(Os),
        (   ground(X) ->
            trigger_props_(Gs),
            trigger_props_(Bs)
        ;   Bs \== [] ->
            domain_infimum(D0, I0),
            domain_infimum(D, I),
            (   I == I0 ->
                domain_supremum(D0, S0),
                domain_supremum(D, S),
                (   S == S0 -> true
                ;   trigger_props_(Bs)
                )
            ;   trigger_props_(Bs)
            )
        ;   true
        ).


trigger_props(fd_props(Gs,Bs,Os), X) :-
        trigger_props_(Os),
        trigger_props_(Bs),
        (   ground(X) ->
            trigger_props_(Gs)
        ;   true
        ).

trigger_props(fd_props(Gs,Bs,Os)) :-
        trigger_props_(Gs),
        trigger_props_(Bs),
        trigger_props_(Os).

trigger_props_([]).
trigger_props_([P|Ps]) :- trigger_prop(P), trigger_props_(Ps).

trigger_prop(Propagator) :-
        arg(2, Propagator, State),
        (   State == dead -> true
        ;   get_attr(State, clpfd_aux, queued) -> true
        ;   b_getval('$clpfd_current_propagator', C), C == State -> true
        ;   % passive
            % format("triggering: ~w\n", [Propagator]),
            put_attr(State, clpfd_aux, queued),
            push_queue(Propagator)
        ).

kill(State) :- del_attr(State, clpfd_aux), State = dead.

kill(State, Ps) :-
        kill(State),
        maplist(kill_entailed, Ps).

kill_entailed(p(Prop)) :-
        arg(2, Prop, State),
        kill(State).
kill_entailed(a(V)) :-
        del_attr(V, clpfd).
kill_entailed(a(X,B)) :-
        (   X == B -> true
        ;   del_attr(B, clpfd)
        ).
kill_entailed(a(X,Y,B)) :-
        (   X == B -> true
        ;   Y == B -> true
        ;   del_attr(B, clpfd)
        ).

no_reactivation(rel_tuple(_,_)).
%no_reactivation(scalar_product(_,_,_,_)).

activate_propagator(propagator(P,State)) :-
        % format("running: ~w\n", [P]),
        del_attr(State, clpfd_aux),
        (   no_reactivation(P) ->
            b_setval('$clpfd_current_propagator', State),
            run_propagator(P, State),
            b_setval('$clpfd_current_propagator', [])
        ;   run_propagator(P, State)
        ).

disable_queue :- b_setval('$clpfd_queue_status', disabled).
enable_queue  :- b_setval('$clpfd_queue_status', enabled).

portray_propagator(propagator(P,_), F) :- functor(P, F, _).

portray_queue(V, []) :- var(V), !.
portray_queue([P|Ps], [F|Fs]) :-
        portray_propagator(P, F),
        portray_queue(Ps, Fs).

do_queue :-
        % b_getval('$clpfd_queue', H-_),
        % portray_queue(H, Port),
        % format("queue: ~w\n", [Port]),
        (   b_getval('$clpfd_queue_status', enabled) ->
            (   fetch_propagator(Propagator) ->
                activate_propagator(Propagator),
                do_queue
            ;   true
            )
        ;   true
        ).

init_propagator(Var, Prop) :-
        (   fd_get(Var, Dom, Ps0) ->
            insert_propagator(Prop, Ps0, Ps),
            fd_put(Var, Dom, Ps)
        ;   true
        ).

constraint_wake(pneq, ground).
constraint_wake(x_neq_y_plus_z, ground).
constraint_wake(absdiff_neq, ground).
constraint_wake(pdifferent, ground).
constraint_wake(pdistinct, ground).
constraint_wake(scalar_product_neq, ground).

constraint_wake(x_leq_y_plus_c, bounds).
constraint_wake(scalar_product_eq, bounds).
constraint_wake(pplus, bounds).
constraint_wake(pgeq, bounds).

insert_propagator(Prop, Ps0, Ps) :-
        Ps0 = fd_props(Gs,Bs,Os),
        arg(1, Prop, Constraint),
        functor(Constraint, F, _),
        (   constraint_wake(F, ground) ->
            Ps = fd_props([Prop|Gs], Bs, Os)
        ;   constraint_wake(F, bounds) ->
            Ps = fd_props(Gs, [Prop|Bs], Os)
        ;   Ps = fd_props(Gs, Bs, [Prop|Os])
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% lex_chain(+Lists)
%
% Lists are lexicographically non-decreasing.

lex_chain(Lss) :-
        must_be(list(list), Lss),
        make_propagator(presidual(lex_chain(Lss)), Prop),
        lex_chain_(Lss, Prop).

lex_chain_([], _).
lex_chain_([Ls|Lss], Prop) :-
        lex_check_and_attach(Ls, Prop),
        lex_chain_lag(Lss, Ls),
        lex_chain_(Lss, Prop).

lex_check_and_attach([], _).
lex_check_and_attach([L|Ls], Prop) :-
        fd_variable(L),
        (   var(L) ->
            init_propagator(L, Prop)
        ;   true
        ),
        lex_check_and_attach(Ls, Prop).

lex_chain_lag([], _).
lex_chain_lag([Ls|Lss], Ls0) :-
        lex_le(Ls0, Ls),
        lex_chain_lag(Lss, Ls).

lex_le([], []).
lex_le([V1|V1s], [V2|V2s]) :-
        V1 #=< V2,
        (   integer(V1) ->
            (   integer(V2) ->
                (   V1 =:= V2 -> lex_le(V1s, V2s) ;  true )
            ;   freeze(V2, lex_le([V1|V1s], [V2|V2s]))
            )
        ;   freeze(V1, lex_le([V1|V1s], [V2|V2s]))
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% tuples_in(+Tuples, +Relation).
%
% Relation must be a list of lists of integers. The elements of the
% list Tuples are constrained to be elements of Relation. Arbitrary
% finite relations, such as compatibility tables, can be modeled in
% this way. For example, if 1 is compatible with 2 and 5, and 4 is
% compatible with 0 and 3:
%
% ==
% ?- tuples_in([[X,Y]], [[1,2],[1,5],[4,0],[4,3]]), X = 4.
% X = 4,
% Y in 0\/3.
% ==
%
% As another example, consider a train schedule represented as a list
% of quadruples, denoting departure and arrival places and times for
% each train. In the following program, Ps is a feasible journey of
% length 3 from A to D via trains that are part of the given schedule.
%
% ==
% :- use_module(library(clpfd)).
%
% trains([[1,2,0,1],[2,3,4,5],[2,3,0,1],[3,4,5,6],[3,4,2,3],[3,4,8,9]]).
%
% threepath(A, D, Ps) :-
%         Ps = [[A,B,_T0,T1],[B,C,T2,T3],[C,D,T4,_T5]],
%         T2 #> T1,
%         T4 #> T3,
%         trains(Ts),
%         tuples_in(Ps, Ts).
% ==
%
% In this example, the unique solution is found without labeling:
%
% ==
% ?- threepath(1, 4, Ps).
% Ps = [[1, 2, 0, 1], [2, 3, 4, 5], [3, 4, 8, 9]].
% ==

tuples_in(Tuples, Relation) :-
        must_be(list, Tuples),
        append(Tuples, Vs),
        maplist(fd_variable, Vs),
        must_be(list(list(integer)), Relation),
        tuples_domain(Tuples, Relation),
        do_queue.

tuples_domain([], _).
tuples_domain([Tuple|Tuples], Relation) :-
        relation_unifiable(Relation, Tuple, Us, 0, _),
        (   ground(Tuple) -> memberchk(Tuple, Relation)
        ;   tuple_domain(Tuple, Us),
            (   Tuple = [_,_|_] -> tuple_freeze(Tuple, Us)
            ;   true
            )
        ),
        tuples_domain(Tuples, Relation).

tuple_domain([], _).
tuple_domain([T|Ts], Relation0) :-
        take_firsts(Relation0, Firsts, Relation1),
        ( var(T) ->
            (   Firsts = [Unique] -> T = Unique
            ;   list_to_domain(Firsts, FDom),
                fd_get(T, TDom, TPs),
                domains_intersection(TDom, FDom, TDom1),
                fd_put(T, TDom1, TPs)
            )
        ;   true
        ),
        tuple_domain(Ts, Relation1).

take_firsts([], [], []).
take_firsts([[F|Os]|Rest], [F|Fs], [Os|Oss]) :-
        take_firsts(Rest, Fs, Oss).

tuple_freeze(Tuple, Relation) :-
        make_propagator(rel_tuple(mutable(Relation,_),Tuple), Prop),
        tuple_freeze(Tuple, Tuple, Prop).

tuple_freeze([],  _, _).
tuple_freeze([T|Ts], Tuple, Prop) :-
        ( var(T) ->
            init_propagator(T, Prop),
            trigger_prop(Prop)
        ;   true
        ),
        tuple_freeze(Ts, Tuple, Prop).

relation_unifiable([], _, [], Changed, Changed).
relation_unifiable([R|Rs], Tuple, Us, Changed0, Changed) :-
        (   all_in_domain(R, Tuple) ->
            Us = [R|Rest],
            relation_unifiable(Rs, Tuple, Rest, Changed0, Changed)
        ;   relation_unifiable(Rs, Tuple, Us, 1, Changed)
        ).

all_in_domain([], []).
all_in_domain([A|As], [T|Ts]) :-
        (   fd_get(T, Dom, _) ->
            domain_contains(Dom, A)
        ;   T =:= A
        ),
        all_in_domain(As, Ts).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% trivial propagator, used only to remember pending constraints
run_propagator(presidual(_), _).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(pdifferent(Left,Right,X,_), _MState) :-
        (   ground(X) ->
            disable_queue,
            exclude_fire(Left, Right, X),
            enable_queue
        ;   true
        ).

run_propagator(pdistinct(Left,Right,X,_), _MState) :-
        (   ground(X) ->
            disable_queue,
            exclude_fire(Left, Right, X),
            enable_queue
        ;   %outof_reducer(Left, Right, X)
            %(   var(X) -> kill_if_isolated(Left, Right, X, MState)
            %;   true
            %),
            true
        ).

run_propagator(check_distinct(Left,Right,X), _) :-
        \+ list_contains(Left, X),
        \+ list_contains(Right, X).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(pneq(A, B), MState) :-
        (   nonvar(A) ->
            (   nonvar(B) -> A =\= B, kill(MState)
            ;   fd_get(B, BD0, BExp0),
                domain_remove(BD0, A, BD1),
                kill(MState),
                fd_put(B, BD1, BExp0)
            )
        ;   nonvar(B) -> run_propagator(pneq(B, A), MState)
        ;   A \== B,
            fd_get(A, _, AI, AS, _), fd_get(B, _, BI, BS, _),
            (   AS cis_lt BI -> kill(MState)
            ;   AI cis_gt BS -> kill(MState)
            ;   true
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(pgeq(A,B), MState) :-
        (   A == B -> kill(MState)
        ;   nonvar(A) ->
            (   nonvar(B) -> kill(MState), A >= B
            ;   fd_get(B, BD, BPs),
                domain_remove_greater_than(BD, A, BD1),
                kill(MState),
                fd_put(B, BD1, BPs)
            )
        ;   nonvar(B) ->
            fd_get(A, AD, APs),
            domain_remove_smaller_than(AD, B, AD1),
            kill(MState),
            fd_put(A, AD1, APs)
        ;   fd_get(A, AD, AL, AU, APs),
            fd_get(B, _, BL, BU, _),
            AU cis_geq BL,
            (   AL cis_geq BU -> kill(MState)
            ;   AU == BL -> kill(MState), A = B
            ;   NAL cis max(AL,BL),
                domains_intersection(AD, from_to(NAL,AU), NAD),
                fd_put(A, NAD, APs),
                (   fd_get(B, BD2, BL2, BU2, BPs2) ->
                    NBU cis min(BU2, AU),
                    domains_intersection(BD2, from_to(BL2,NBU), NBD),
                    fd_put(B, NBD, BPs2)
                ;   true
                )
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run_propagator(rel_tuple(Rel, Tuple), MState) :-
        arg(1, Rel, Relation),
        (   ground(Tuple) -> kill(MState), memberchk(Tuple, Relation)
        ;   relation_unifiable(Relation, Tuple, Us, 0, Changed),
            Us = [_|_],
            (   Tuple = [First,Second], ( ground(First) ; ground(Second) ) ->
                kill(MState)
            ;   true
            ),
            (   Us = [Single] -> kill(MState), Single = Tuple
            ;   Changed =:= 0 -> true
            ;   setarg(1, Rel, Us),
                disable_queue,
                tuple_domain(Tuple, Us),
                enable_queue
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run_propagator(pserialized(Var,Duration,Left,SDs), _MState) :-
        myserialized(Duration, Left, SDs, Var).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% abs(X-Y) #\= C
run_propagator(absdiff_neq(X,Y,C), MState) :-
        (   C < 0 -> kill(MState)
        ;   nonvar(X) ->
            kill(MState),
            (   nonvar(Y) -> abs(X - Y) =\= C
            ;   V1 is X - C, neq_num(Y, V1),
                V2 is C + X, neq_num(Y, V2)
            )
        ;   nonvar(Y) -> kill(MState),
            V1 is C + Y, neq_num(X, V1),
            V2 is Y - C, neq_num(X, V2)
        ;   true
        ).

% abs(X-Y) #>= C
run_propagator(absdiff_geq(X,Y,C), MState) :-
        (   C =< 0 -> kill(MState)
        ;   nonvar(X) ->
            kill(MState),
            (   nonvar(Y) -> abs(X-Y) >= C
            ;   P1 is X - C, P2 is X + C,
                Y in inf..P1 \/ P2..sup
            )
        ;   nonvar(Y) ->
            kill(MState),
            P1 is Y - C, P2 is Y + C,
            X in inf..P1 \/ P2..sup
        ;   true
        ).

% X #\= Y + Z
run_propagator(x_neq_y_plus_z(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) ->
                (   nonvar(Z) -> kill(MState), X =\= Y + Z
                ;   kill(MState), XY is X - Y, neq_num(Z, XY)
                )
            ;   nonvar(Z) -> kill(MState), XZ is X - Z, neq_num(Y, XZ)
            ;   true
            )
        ;   nonvar(Y) ->
            (   nonvar(Z) ->
                kill(MState), YZ is Y + Z, neq_num(X, YZ)
            ;   Y =:= 0 -> kill(MState), neq(X, Z)
            ;   true
            )
        ;   Z == 0 -> kill(MState), neq(X, Y)
        ;   true
        ).

% X #=< Y + C
run_propagator(x_leq_y_plus_c(X,Y,C), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) -> kill(MState), X =< Y + C
            ;   kill(MState),
                R is X - C,
                fd_get(Y, YD, YPs),
                domain_remove_smaller_than(YD, R, YD1),
                fd_put(Y, YD1, YPs)
            )
        ;   nonvar(Y) ->
            kill(MState),
            R is Y + C,
            fd_get(X, XD, XPs),
            domain_remove_greater_than(XD, R, XD1),
            fd_put(X, XD1, XPs)
        ;   fd_get(Y, YD, _),
            (   domain_supremum(YD, n(YSup)) ->
                YS1 is YSup + C,
                fd_get(X, XD, XPs),
                domain_remove_greater_than(XD, YS1, XD1),
                fd_put(X, XD1, XPs)
            ;   true
            ),
            (   fd_get(X, XD2, _), domain_infimum(XD2, n(XInf)) ->
                XI1 is XInf - C,
                (   fd_get(Y, YD1, YPs1) ->
                    domain_remove_smaller_than(YD1, XI1, YD2),
                    (   domain_infimum(YD2, n(YInf)),
                        domain_supremum(XD2, n(XSup)),
                        XSup =< YInf + C ->
                        kill(MState)
                    ;   true
                    ),
                    fd_put(Y, YD2, YPs1)
                ;   true
                )
            ;   true
            )
        ).

run_propagator(scalar_product_neq(Cs0,Vs0,P0), MState) :-
        coeffs_variables_const(Cs0, Vs0, Cs, Vs, 0, I),
        P is P0 - I,
        (   Vs = [] -> kill(MState), P =\= 0
        ;   Vs = [V], Cs = [C] ->
            kill(MState),
            (   C =:= 1 -> neq_num(V, P)
            ;   C*V #\= P
            )
        ;   Cs == [1,-1] -> kill(MState), Vs = [A,B], x_neq_y_plus_z(A, B, P)
        ;   Cs == [-1,1] -> kill(MState), Vs = [A,B], x_neq_y_plus_z(B, A, P)
        ;   P =:= 0, Cs = [1,1,-1] ->
            kill(MState), Vs = [A,B,C], x_neq_y_plus_z(C, A, B)
        ;   P =:= 0, Cs = [1,-1,1] ->
            kill(MState), Vs = [A,B,C], x_neq_y_plus_z(B, A, C)
        ;   P =:= 0, Cs = [-1,1,1] ->
            kill(MState), Vs = [A,B,C], x_neq_y_plus_z(A, B, C)
        ;   true
        ).

run_propagator(scalar_product_eq(Cs0,Vs0,P0), MState) :-
        coeffs_variables_const(Cs0, Vs0, Cs, Vs, 0, I),
        P is P0 - I,
        (   Vs = [] -> kill(MState), P =:= 0
        ;   Vs = [V], Cs = [C] -> kill(MState), P mod C =:= 0, V is P // C
        ;   Cs == [1,1] -> kill(MState), Vs = [A,B], A + B #= P
        ;   Cs == [1,-1] -> kill(MState), Vs = [A,B], A #= P + B
        ;   Cs == [-1,1] -> kill(MState), Vs = [A,B], B #= P + A
        ;   Cs == [-1,-1] -> kill(MState), Vs = [A,B], P1 is -P, A + B #= P1
        ;   P =:= 0, Cs == [1,1,-1] -> kill(MState), Vs = [A,B,C], A + B #= C
        ;   P =:= 0, Cs == [1,-1,1] -> kill(MState), Vs = [A,B,C], A + C #= B
        ;   P =:= 0, Cs == [-1,1,1] -> kill(MState), Vs = [A,B,C], B + C #= A
        ;   sum_finite_domains(Cs, Vs, Infs, Sups, 0, 0, Inf, Sup),
            % nl, writeln(Infs-Sups-Inf-Sup),
            D1 is P - Inf,
            D2 is Sup - P,
            disable_queue,
            (   Infs == [], Sups == [] ->
                between(Inf, Sup, P),
                remove_dist_upper_lower(Cs, Vs, D1, D2)
            ;   Sups = [] -> P =< Sup, remove_dist_lower(Infs, D2)
            ;   Infs = [] -> Inf =< P, remove_dist_upper(Sups, D1)
            ;   Sups = [_], Infs = [_] ->
                remove_lower(Sups, D2),
                remove_upper(Infs, D1)
            ;   Infs = [_] -> remove_upper(Infs, D1)
            ;   Sups = [_] -> remove_lower(Sups, D2)
            ;   true
            ),
            enable_queue
        ).

% X + Y = Z
run_propagator(pplus(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   X =:= 0 -> kill(MState), Y = Z
            ;   Y == Z -> kill(MState), X =:= 0
            ;   nonvar(Y) -> kill(MState), Z is X + Y
            ;   nonvar(Z) -> kill(MState), Y is Z - X
            ;   fd_get(Z, ZD, ZPs),
                fd_get(Y, YD, _),
                domain_shift(YD, X, Shifted_YD),
                domains_intersection(ZD, Shifted_YD, ZD1),
                fd_put(Z, ZD1, ZPs),
                (   fd_get(Y, YD1, YPs) ->
                    O is -X,
                    domain_shift(ZD1, O, YD2),
                    domains_intersection(YD1, YD2, YD3),
                    fd_put(Y, YD3, YPs)
                ;   true
                )
            )
        ;   nonvar(Y) -> run_propagator(pplus(Y,X,Z), MState)
        ;   nonvar(Z) ->
            (   X == Y -> kill(MState), Z mod 2 =:= 0, X is Z // 2
            ;   fd_get(X, XD, _),
                fd_get(Y, YD, YPs),
                domain_negate(XD, XDN),
                domain_shift(XDN, Z, YD1),
                domains_intersection(YD, YD1, YD2),
                fd_put(Y, YD2, YPs),
                (   fd_get(X, XD1, XPs) ->
                    domain_negate(YD2, YD2N),
                    domain_shift(YD2N, Z, XD2),
                    domains_intersection(XD1, XD2, XD3),
                    fd_put(X, XD3, XPs)
                ;   true
                )
            )
        ;   (   X == Y -> kill(MState), 2*X #= Z
            ;   X == Z -> kill(MState), Y = 0
            ;   Y == Z -> kill(MState), X = 0
            ;   fd_get(X, XD, XL, XU, XPs), fd_get(Y, YD, YL, YU, YPs),
                fd_get(Z, ZD, ZL, ZU, _) ->
                NXL cis max(XL, ZL-YU),
                NXU cis min(XU, ZU-YL),
                (   NXL == XL, NXU == XU -> true
                ;   domains_intersection(XD, from_to(NXL, NXU), NXD),
                    fd_put(X, NXD, XPs)
                ),
                (   fd_get(Y, YD2, YL2, YU2, YPs2) ->
                    NYL cis max(YL2, ZL-NXU),
                    NYU cis min(YU2, ZU-NXL),
                    (   NYL == YL2, NYU == YU2 -> true
                    ;   domains_intersection(YD2, from_to(NYL, NYU), NYD),
                        fd_put(Y, NYD, YPs2)
                    )
                ;   NYL = n(Y), NYU = n(Y)
                ),
                (   fd_get(Z, ZD2, ZL2, ZU2, ZPs2) ->
                    NZL cis max(ZL2,NXL+NYL),
                    NZU cis min(ZU2,NXU+NYU),
                    (   NZL == ZL2, NZU == ZU2 -> true
                    ;   domains_intersection(ZD2, from_to(NZL,NZU), NZD),
                        fd_put(Z, NZD, ZPs2)
                    )
                ;   true
                )
            ;   true
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run_propagator(ptimes(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) -> kill(MState), Z is X * Y
            ;   X =:= 0 -> kill(MState), Z = 0
            ;   X =:= 1 -> kill(MState), Z = Y
            ;   nonvar(Z) -> kill(MState), 0 =:= Z mod X, Y is Z // X
            ;   fd_get(Y, YD, _),
                fd_get(Z, ZD, ZPs),
                domain_expand(YD, X, Scaled_YD),
                domains_intersection(ZD, Scaled_YD, ZD1),
                fd_put(Z, ZD1, ZPs),
                (   fd_get(Y, YDom2, YPs2) ->
                    domain_contract(ZD1, X, Contract),
                    domains_intersection(YDom2, Contract, NYDom),
                    fd_put(Y, NYDom, YPs2)
                ;   kill(MState), Z is X * Y
                )
            )
        ;   nonvar(Y) -> run_propagator(ptimes(Y,X,Z), MState)
        ;   nonvar(Z) ->
            (   X == Y ->
                kill(MState),
                integer_kth_root(Z, 2, R),
                NR is -R,
                X in NR \/ R
            ;   fd_get(X, XD, XL, XU, XPs),
                fd_get(Y, YD, YL, YU, _),
                min_divide(n(Z), n(Z), YL, YU, TNXL),
                max_divide(n(Z), n(Z), YL, YU, TNXU),
                NXL cis max(XL,TNXL),
                NXU cis min(XU,TNXU),
                (   NXL == XL, NXU == XU -> true
                ;   domains_intersection(XD, from_to(NXL,NXU), XD1),
                    fd_put(X, XD1, XPs)
                ),
                (   fd_get(Y, YD2, YL2, YU2,YExp2) ->
                    min_divide(n(Z), n(Z), NXL, NXU, NYL),
                    max_divide(n(Z), n(Z), NXL, NXU, NYU),
                    (   NYL cis_leq YL2, NYU cis_geq YU2 -> true
                    ;   domains_intersection(YD2, from_to(NYL,NYU), YD3),
                        fd_put(Y, YD3, YExp2)
                    )
                ;   (   Y \== 0 -> 0 =:= Z mod Y, kill(MState), X is Z // Y
                    ;   kill(MState), Z = 0
                    )
                )
            ),
            (   Z =\= 0 -> neq_num(X, 0), neq_num(Y, 0)
            ;   true
            )
        ;   (   X == Y -> kill(MState), X^2#=Z
            ;   fd_get(X, XD, XL, XU, XExp),
                fd_get(Y, YD, YL, YU, _),
                fd_get(Z, ZD, ZL, ZU, _),
                min_divide(ZL,ZU,YL,YU,TXL),
                NXL cis max(XL,TXL),
                max_divide(ZL,ZU,YL,YU,TXU),
                NXU cis min(XU,TXU),
                (   NXL == XL, NXU == XU -> true
                ;   domains_intersection(XD, from_to(NXL,NXU), XD1),
                    fd_put(X, XD1, XExp)
                ),
                (   fd_get(Y,YD2,YL2,YU2,YExp2) ->
                    min_divide(ZL,ZU,XL,XU,TYL),
                    NYL cis max(YL2,TYL),
                    max_divide(ZL,ZU,XL,XU,TYU),
                    NYU cis min(YU2,TYU),
                    (   NYL == YL2, NYU == YU2 -> true
                    ;   domains_intersection(YD2, from_to(NYL,NYU), YD3),
                        fd_put(Y, YD3, YExp2)
                    )
                ;   NYL = n(Y), NYU = n(Y)
                ),
                (   fd_get(Z, ZD2, ZL2, ZU2, ZExp2) ->
                    min_times(NXL,NXU,NYL,NYU,NZL),
                    max_times(NXL,NXU,NYL,NYU,NZU),
                    (   NZL cis_leq ZL2, NZU cis_geq ZU2 -> true
                    ;   domains_intersection(ZD2, from_to(NZL,NZU), ZD3),
                        fd_put(Z, ZD3, ZExp2)
                    )
                ;   true
                )
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% X / Y = Z

run_propagator(pdiv(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) -> kill(MState), Y =\= 0, Z is X // Y
            ;   fd_get(Y, YD, YL, YU, YPs),
                (   nonvar(Z) ->
                    (   Z =:= 0 ->
                        NYL is -abs(X) - 1,
                        NYU is abs(X) + 1,
                        domains_intersection(YD, split(0, from_to(inf,n(NYL)),
                                                       from_to(n(NYU), sup)),
                                             NYD),
                        fd_put(Y, NYD, YPs)
                    ;   (   sign(X) =:= sign(Z) ->
                            NYL cis max(n(X) // (n(Z)+sign(n(Z))) + n(1), YL),
                            NYU cis min(n(X) // n(Z), YU)
                        ;   NYL cis max(n(X) // n(Z), YL),
                            NYU cis min(n(X) // (n(Z)+sign(n(Z))) - n(1), YU)
                        ),
                        (   NYL = YL, NYU = YU -> true
                        ;   domains_intersection(YD, from_to(NYL,NYU), NYD),
                            fd_put(Y, NYD, YPs)
                        )
                    )
                ;   fd_get(Z, ZD, ZL, ZU, ZPs),
                    (   X >= 0, YL cis_gt n(0) ->
                        NZL cis max(n(X)//YU, ZL),
                        NZU cis min(n(X)//YL, ZU)
                    ;   % TODO: more stringent bounds, cover Y
                        NZL cis max(-abs(n(X)), ZL),
                        NZU cis min(abs(n(X)), ZU)
                    ),
                    (   NZL = ZL, NZU = ZU -> true
                    ;   domains_intersection(ZD, from_to(NZL,NZU), NZD),
                        fd_put(Z, NZD, ZPs)
                    )
                )
            )
        ;   nonvar(Y) ->
            Y =\= 0,
            (   Y =:= 1 -> kill(MState), X = Z
            ;   Y =:= -1 -> kill(MState), Z #= -X
            ;   fd_get(X, XD, XL, XU, XPs),
                (   nonvar(Z) ->
                    (   sign(Z) =:= sign(Y) ->
                        NXL cis max(n(Z)*n(Y), XL),
                        NXU cis min((abs(n(Z))+n(1))*abs(n(Y))-n(1), XU)
                    ;   Z =:= 0 ->
                        NXL cis max(-abs(n(Y)) + n(1), XL),
                        NXU cis min(abs(n(Y)) - n(1), XU)
                    ;   NXL cis max((n(Z)+sign(n(Z))*n(1))*n(Y)+n(1), XL),
                        NXU cis min(n(Z)*n(Y), XU)
                    ),
                    (   NXL == XL, NXU == XU -> true
                    ;   domains_intersection(XD, from_to(NXL,NXU), NXD),
                        fd_put(X, NXD, XPs)
                    )
                ;   fd_get(Z, ZD, ZPs),
                    domain_contract_less(XD, Y, Contracted),
                    domains_intersection(ZD, Contracted, NZD),
                    fd_put(Z, NZD, ZPs),
                    (   \+ domain_contains(NZD, 0), fd_get(X, XD2, XPs2) ->
                        domain_expand_more(NZD, Y, Expanded),
                        domains_intersection(XD2, Expanded, NXD2),
                        fd_put(X, NXD2, XPs2)
                    ;   true
                    )
                )
            )
        ;   nonvar(Z) ->
            fd_get(X, XD, XL, XU, XPs),
            fd_get(Y, YD, YL, YU, YPs),
            (   YL cis_geq n(0), XL cis_geq n(0) ->
                NXL cis max(YL*n(Z), XL),
                NXU cis min(YU*(n(Z)+n(1))-n(1), XU)
            ;   %TODO: cover more cases
                NXL = XL, NXU = XU
            ),
            (   NXL == XL, NXU == XU -> true
            ;   domains_intersection(XD, from_to(NXL,NXU), NXD),
                fd_put(X, NXD, XPs)
            )
        ;   (   X == Y -> Z = 1
            ;   fd_get(X, _, XL, XU, _),
                fd_get(Y, _, YL, YU, _),
                fd_get(Z, ZD, ZPs),
                NZU cis max(abs(XL), XU),
                NZL cis -NZU,
                domains_intersection(ZD, from_to(NZL,NZU), NZD0),
                (   cis_geq_zero(XL), cis_geq_zero(YL) ->
                    domain_remove_smaller_than(NZD0, 0, NZD1)
                ;   % TODO: cover more cases
                    NZD1 = NZD0
                ),
                fd_put(Z, NZD1, ZPs)
            )
        ).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Y = abs(X)

run_propagator(pabs(X,Y), MState) :-
        (   nonvar(X) -> kill(MState), Y is abs(X)
        ;   nonvar(Y) ->
            kill(MState),
            Y >= 0,
            YN is -Y,
            X in YN \/ Y
        ;   fd_get(X, XD, XPs),
            fd_get(Y, YD, _),
            domain_negate(YD, YDNegative),
            domains_union(YD, YDNegative, XD1),
            domains_intersection(XD, XD1, XD2),
            fd_put(X, XD2, XPs),
            (   fd_get(Y, YD1, YPs1) ->
                domain_negate(XD2, XD2Neg),
                domains_union(XD2, XD2Neg, YD2),
                domain_remove_smaller_than(YD2, 0, YD3),
                domains_intersection(YD1, YD3, YD4),
                fd_put(Y, YD4, YPs1)
            ;   true
            )
        ).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% K = X mod M

run_propagator(pmod(X,M,K), MState) :-
        (   nonvar(X) ->
            (   nonvar(M) -> kill(MState), M =\= 0, K is X mod M
            ;   true
            )
        ;   nonvar(M) ->
            M =\= 0,
            (   abs(M) =:= 1 -> kill(MState), K = 0
            ;   fd_get(K, KD, KPs) ->
                MP is abs(M) - 1,
                fd_get(K, KD, KPs),
                (   M > 0 -> KDN = from_to(n(0), n(MP))
                ;   MN is -MP, KDN = from_to(n(MN), n(0))
                ),
                domains_intersection(KD, KDN, KD1),
                fd_put(K, KD1, KPs),
                (   fd_get(X, XD, _), domain_infimum(XD, n(Min)) ->
                    K1 is Min mod M,
                    (   domain_contains(KD1, K1) -> true
                    ;   neq_num(X, Min)
                    )
                ;   true
                ),
                (   fd_get(X, XD1, _), domain_supremum(XD1, n(Max)) ->
                    K2 is Max mod M,
                    (   domain_contains(KD1, K2) -> true
                    ;   neq_num(X, Max)
                    )
                ;   true
                )
            ;   fd_get(X, XD, _),
                % if possible, propagate at the boundaries
                (   nonvar(K), domain_infimum(XD, n(Min)) ->
                    (   Min mod M =:= K -> true
                    ;   neq_num(X, Min)
                    )
                ;   true
                ),
                (   nonvar(K), domain_supremum(XD, n(Max)) ->
                    (   Max mod M =:= K -> true
                    ;   neq_num(X, Max)
                    )
                ;   true
                )
            )
        ;   true % TODO: propagate more
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Z = max(X,Y)

run_propagator(pmax(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) -> kill(MState), Z is max(X,Y)
            ;   nonvar(Z) ->
                (   Z =:= X -> kill(MState), X #>= Y
                ;   Z > X -> Z = Y
                ;   fail % Z < X
                )
            ;   fd_get(Y, YD, YInf, YSup, _),
                (   YInf cis_gt n(X) -> Z = Y
                ;   YSup cis_lt n(X) -> Z = X
                ;   YSup = n(M) ->
                    fd_get(Z, ZD, ZPs),
                    domain_remove_greater_than(ZD, M, ZD1),
                    fd_put(Z, ZD1, ZPs)
                ;   true
                )
            )
        ;   nonvar(Y) -> run_propagator(pmax(Y,X,Z), MState)
        ;   fd_get(Z, ZD, ZPs) ->
            fd_get(X, _, XInf, XSup, _),
            fd_get(Y, YD, YInf, YSup, _),
            (   YInf cis_gt YSup -> kill(MState), Z = Y
            ;   YSup cis_lt XInf -> kill(MState), Z = X
            ;   n(M) cis max(XSup, YSup) ->
                domain_remove_greater_than(ZD, M, ZD1),
                fd_put(Z, ZD1, ZPs)
            ;   true
            )
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Z = min(X,Y)

run_propagator(pmin(X,Y,Z), MState) :-
        (   nonvar(X) ->
            (   nonvar(Y) -> kill(MState), Z is min(X,Y)
            ;   nonvar(Z) ->
                (   Z =:= X -> kill(MState), X #=< Y
                ;   Z < X -> Z = Y
                ;   fail % Z > X
                )
            ;   fd_get(Y, YD, YInf, YSup, _),
                (   YSup cis_lt n(X) -> Z = Y
                ;   YInf cis_gt n(X) -> Z = X
                ;   YInf = n(M) ->
                    fd_get(Z, ZD, ZPs),
                    domain_remove_smaller_than(ZD, M, ZD1),
                    fd_put(Z, ZD1, ZPs)
                ;   true
                )
            )
        ;   nonvar(Y) -> run_propagator(pmin(Y,X,Z), MState)
        ;   fd_get(Z, ZD, ZPs) ->
            fd_get(X, _, XInf, XSup, _),
            fd_get(Y, YD, YInf, YSup, _),
            (   YSup cis_lt YInf -> kill(MState), Z = Y
            ;   YInf cis_gt XSup -> kill(MState), Z = X
            ;   n(M) cis min(XInf, YInf) ->
                domain_remove_smaller_than(ZD, M, ZD1),
                fd_put(Z, ZD1, ZPs)
            ;   true
            )
        ;   true
        ).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Z = X ^ Y

run_propagator(pexp(X,Y,Z), MState) :-
        (   X == 1 -> kill(MState), Z = 1
        ;   X == 0 -> kill(MState), Z #<==> Y #= 0
        ;   Y == 0 -> kill(MState), Z = 1
        ;   Y == 1 -> kill(MState), Z = X
        ;   nonvar(X), nonvar(Y) ->
            ( Y >= 0 -> true ; X =:= -1 ),
            kill(MState),
            Z is X^Y
        ;   nonvar(Z), nonvar(Y) ->
            integer_kth_root(Z, Y, R),
            kill(MState),
            (   Y mod 2 =:= 0 ->
                N is -R,
                X in N \/ R
            ;   X = R
            )
        ;   nonvar(Y), Y > 0 ->
            (   Y mod 2 =:= 0 ->
                geq(Z, 0)
            ;   true
            ),
            (   fd_get(X, XD, XL, XU, _), fd_get(Z, ZD, ZPs) ->
                (   domain_contains(ZD, 0) -> true
                ;   neq_num(X, 0)
                ),
                (   domain_contains(XD, 0) -> true
                ;   neq_num(Z, 0)
                ),
                (   XL = n(NXL), NXL >= 0 ->
                    NZL is NXL ^ Y,
                    domain_remove_smaller_than(ZD, NZL, ZD1),
                    (   XU = n(NXU) ->
                        NZU is NXU ^ Y,
                        domain_remove_greater_than(ZD1, NZU, ZD2)
                    ;   ZD2 = ZD1
                    ),
                    fd_put(Z, ZD2, ZPs)
                ;   true        % TODO: propagate more
                )
            ;   true
            )
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(pzcompare(Order, A, B), MState) :-
        (   A == B -> kill(MState), Order = (=)
        ;   (   nonvar(A) ->
                (   nonvar(B) ->
                    kill(MState),
                    (   A > B -> Order = (>)
                    ;   Order = (<)
                    )
                ;   fd_get(B, _, BL, BU, _),
                    (   BL cis_gt n(A) -> kill(MState), Order = (<)
                    ;   BU cis_lt n(A) -> kill(MState), Order = (>)
                    ;   true
                    )
                )
            ;   nonvar(B) ->
                fd_get(A, _, AL, AU, _),
                (   AL cis_gt n(B) -> kill(MState), Order = (>)
                ;   AU cis_lt n(B) -> kill(MState), Order = (<)
                ;   true
                )
            ;   fd_get(A, _, AL, AU, _),
                fd_get(B, _, BL, BU, _),
                (   AL cis_gt BU -> kill(MState), Order = (>)
                ;   AU cis_lt BL -> kill(MState), Order = (<)
                ;   true
                )
            )
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% reified constraints

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run_propagator(reified_in(V,Dom,B), MState) :-
        (   integer(V) ->
            kill(MState),
            (   domain_contains(Dom, V) -> B = 1
            ;   B = 0
            )
        ;   B == 1 -> kill(MState), domain(V, Dom)
        ;   B == 0 -> kill(MState), domain_complement(Dom, C), domain(V, C)
        ;   fd_get(V, VD, _),
            (   domains_intersection(VD, Dom, I) ->
                (   I == VD -> kill(MState), B = 1
                ;   true
                )
            ;   kill(MState), B = 0
            )
        ).

run_propagator(reified_fd(V,B), MState) :-
        (   fd_inf(V, I), I \== inf, fd_sup(V, S), S \== sup ->
            kill(MState),
            B = 1
        ;   B == 0 ->
            (   fd_inf(V, inf) -> true
            ;   fd_sup(V, sup) -> true
            ;   fail
            )
        ;   true
        ).

% The result of X/Y and X mod Y is undefined iff Y is 0.

run_propagator(reified_div(X,Y,D,Skel,Z), MState) :-
        (   Y == 0 -> kill(MState), D = 0
        ;   D == 1 -> kill(MState), neq_num(Y, 0), skeleton([X,Y,Z], Skel)
        ;   integer(Y), Y =\= 0 -> kill(MState), D = 1, skeleton([X,Y,Z], Skel)
        ;   fd_get(Y, YD, _), \+ domain_contains(YD, 0) ->
            kill(MState),
            D = 1, skeleton([X,Y,Z], Skel)
        ;   true
        ).

run_propagator(reified_mod(X,Y,D,Skel,Z), MState) :-
        (   Y == 0 -> kill(MState), D = 0
        ;   D == 1 -> kill(MState), neq_num(Y, 0), skeleton([X,Y,Z], Skel)
        ;   integer(Y), Y =\= 0 -> kill(MState), D = 1, skeleton([X,Y,Z], Skel)
        ;   fd_get(Y, YD, _), \+ domain_contains(YD, 0) ->
            kill(MState),
            D = 1, skeleton([X,Y,Z], Skel)
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run_propagator(reified_geq(DX,X,DY,Y,Ps,B), MState) :-
        (   DX == 0 -> kill(MState, Ps), B = 0
        ;   DY == 0 -> kill(MState, Ps), B = 0
        ;   B == 1 -> kill(MState), DX = 1, DY = 1, geq(X, Y)
        ;   DX == 1, DY == 1 ->
            (   var(B) ->
                (   nonvar(X) ->
                    (   nonvar(Y) ->
                        kill(MState),
                        (   X >= Y -> B = 1 ; B = 0 )
                    ;   fd_get(Y, _, YL, YU, _),
                        (   n(X) cis_geq YU -> kill(MState, Ps), B = 1
                        ;   n(X) cis_lt YL -> kill(MState, Ps), B = 0
                        ;   true
                        )
                    )
                ;   nonvar(Y) ->
                    fd_get(X, _, XL, XU, _),
                    (   XL cis_geq n(Y) -> kill(MState, Ps), B = 1
                    ;   XU cis_lt n(Y) -> kill(MState, Ps), B = 0
                    ;   true
                    )
                ;   fd_get(X, _, XL, XU, _),
                    fd_get(Y, _, YL, YU, _),
                    (   XL cis_geq YU -> kill(MState, Ps), B = 1
                    ;   XU cis_lt YL -> kill(MState, Ps), B = 0
                    ;   true
                    )
                )
            ;   B =:= 0 -> kill(MState), X #< Y
            ;   true
            )
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(reified_eq(DX,X,DY,Y,Ps,B), MState) :-
        (   DX == 0 -> kill(MState, Ps), B = 0
        ;   DY == 0 -> kill(MState, Ps), B = 0
        ;   B == 1 -> kill(MState), DX = 1, DY = 1, X = Y
        ;   DX == 1, DY == 1 ->
            (   var(B) ->
                (   nonvar(X) ->
                    (   nonvar(Y) ->
                        kill(MState),
                        (   X =:= Y -> B = 1 ; B = 0)
                    ;   fd_get(Y, YD, _),
                        (   domain_contains(YD, X) -> true
                        ;   kill(MState, Ps), B = 0
                        )
                    )
                ;   nonvar(Y) -> run_propagator(reified_eq(DY,Y,DX,X,Ps,B), MState)
                ;   X == Y -> kill(MState), B = 1
                ;   fd_get(X, _, XL, XU, _),
                    fd_get(Y, _, YL, YU, _),
                    (   XL cis_gt YU -> kill(MState, Ps), B = 0
                    ;   YL cis_gt XU -> kill(MState, Ps), B = 0
                    ;   true
                    )
                )
            ;   B =:= 0 -> kill(MState), X #\= Y
            ;   true
            )
        ;   true
        ).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(reified_neq(DX,X,DY,Y,Ps,B), MState) :-
        (   DX == 0 -> kill(MState, Ps), B = 0
        ;   DY == 0 -> kill(MState, Ps), B = 0
        ;   B == 1 -> kill(MState), DX = 1, DY = 1, X #\= Y
        ;   DX == 1, DY == 1 ->
            (   var(B) ->
                (   nonvar(X) ->
                    (   nonvar(Y) ->
                        kill(MState),
                        (   X =\= Y -> B = 1 ; B = 0)
                    ;   fd_get(Y, YD, _),
                        (   domain_contains(YD, X) -> true
                        ;   kill(MState, Ps),
                            B = 1
                        )
                    )
                ;   nonvar(Y) -> run_propagator(reified_neq(DY,Y,DX,X,Ps,B), MState)
                ;   X == Y -> B = 0
                ;   fd_get(X, _, XL, XU, _),
                    fd_get(Y, _, YL, YU, _),
                    (   XL cis_gt YU -> kill(MState, Ps), B = 1
                    ;   YL cis_gt XU -> kill(MState, Ps), B = 1
                    ;   true
                    )
                )
            ;   B =:= 0 -> kill(MState), X = Y
            ;   true
            )
        ;   true
        ).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(reified_and(X,Ps1,Y,Ps2,B), MState) :-
        (   nonvar(X) ->
            kill(MState),
            (   X =:= 0 -> maplist(kill_entailed, Ps2), B = 0
            ;   B = Y
            )
        ;   nonvar(Y) -> run_propagator(reified_and(Y,Ps2,X,Ps1,B), MState)
        ;   B == 1 -> kill(MState), X = 1, Y = 1
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(reified_or(X,Ps1,Y,Ps2,B), MState) :-
        (   nonvar(X) ->
            kill(MState),
            (   X =:= 1 -> maplist(kill_entailed, Ps2), B = 1
            ;   B = Y
            )
        ;   nonvar(Y) -> run_propagator(reified_or(Y,Ps2,X,Ps1,B), MState)
        ;   B == 0 -> kill(MState), X = 0, Y = 0
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(reified_not(X,Y), MState) :-
        (   X == 0 -> kill(MState), Y = 1
        ;   X == 1 -> kill(MState), Y = 0
        ;   Y == 0 -> kill(MState), X = 1
        ;   Y == 1 -> kill(MState), X = 0
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
run_propagator(pimpl(X, Y, Ps), MState) :-
        (   nonvar(X) ->
            kill(MState),
            (   X =:= 1 -> Y = 1
            ;   maplist(kill_entailed, Ps)
            )
        ;   nonvar(Y) ->
            kill(MState),
            (   Y =:= 0 -> X = 0
            ;   maplist(kill_entailed, Ps)
            )
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

min_times(L1,U1,L2,U2,Min) :-
        Min cis min(min(L1*L2,L1*U2),min(U1*L2,U1*U2)).
max_times(L1,U1,L2,U2,Max) :-
        Max cis max(max(L1*L2,L1*U2),max(U1*L2,U1*U2)).


min_divide_less(L1,U1,L2,U2,Min) :-
        (   L2 cis_leq n(0), cis_geq_zero(U2) -> Min = inf
        ;   Min cis min(min(div(L1,L2),div(L1,U2)),min(div(U1,L2),div(U1,U2)))
        ).
max_divide_less(L1,U1,L2,U2,Max) :-
        (   L2 cis_leq n(0), cis_geq_zero(U2) -> Max = sup
        ;   Max cis max(max(div(L1,L2),div(L1,U2)),max(div(U1,L2),div(U1,U2)))
        ).


min_divide(L1,U1,L2,U2,Min) :-
        (   L2 = n(NL2), NL2 > 0, U2 = n(_), cis_geq_zero(L1) ->
            Min cis div(L1+U2-n(1),U2)
                                % TODO: cover more cases
        ;   L2 cis_leq n(0), cis_geq_zero(U2) -> Min = inf
        ;   Min cis min(min(div(L1,L2),div(L1,U2)),min(div(U1,L2),div(U1,U2)))
        ).
max_divide(L1,U1,L2,U2,Max) :-
        (   L2 = n(_), cis_geq_zero(L1), cis_geq_zero(L2) ->
            Max cis div(U1,L2)
                                % TODO: cover more cases
        ;   L2 cis_leq n(0), cis_geq_zero(U2) -> Max = sup
        ;   Max cis max(max(div(L1,L2),div(L1,U2)),max(div(U1,L2),div(U1,U2)))
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Weak arc consistent all_distinct/1 constraint.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

%% all_distinct(+Ls).
%
% Like all_different/1, with stronger propagation.

%all_distinct(Ls) :- all_different(Ls).
all_distinct(Ls) :-
        must_be(list, Ls),
        all_distinct(Ls, [], _),
        do_queue.

all_distinct([], _, _).
all_distinct([X|Right], Left, MState) :-
        %\+ list_contains(Right, X),
        (   var(X) ->
            make_propagator(pdistinct(Left,Right,X,MState), Prop),
            init_propagator(X, Prop),
            trigger_prop(Prop)
%             make_propagator(check_distinct(Left,Right,X), Prop2),
%             init_propagator(X, Prop2),
%             trigger_prop(Prop2)
        ;   exclude_fire(Left, Right, X)
        ),
        outof_reducer(Left, Right, X),
        all_distinct(Right, [X|Left], MState).

exclude_fire(Left, Right, E) :-
        exclude_list(Left, E),
        exclude_list(Right, E).

exclude_list([], _).
exclude_list([V|Vs], Val) :-
        (   fd_get(V, VD, VPs) ->
            domain_remove(VD, Val, VD1),
            fd_put(V, VD1, VPs)
        ;   V =\= Val
        ),
        exclude_list(Vs, Val).

list_contains([X|Xs], Y) :-
        (   X == Y -> true
        ;   list_contains(Xs, Y)
        ).

kill_if_isolated(Left, Right, X, MState) :-
        append(Left, Right, Others),
        fd_get(X, XDom, _),
        (   all_empty_intersection(Others, XDom) -> kill(MState)
        ;   true
        ).

all_empty_intersection([], _).
all_empty_intersection([V|Vs], XDom) :-
        (   fd_get(V, VDom, _) ->
            domains_intersection_(VDom, XDom, empty),
            all_empty_intersection(Vs, XDom)
        ;   all_empty_intersection(Vs, XDom)
        ).

outof_reducer(Left, Right, Var) :-
        (   fd_get(Var, Dom, _) ->
            append(Left, Right, Others),
            domain_num_elements(Dom, N),
            num_subsets(Others, Dom, 0, Num, NonSubs),
            (   n(Num) cis_geq N -> fail
            ;   n(Num) cis N - n(1) ->
                reduce_from_others(NonSubs, Dom)
            ;   true
            )
        ;   %\+ list_contains(Right, Var),
            %\+ list_contains(Left, Var)
            true
        ).

reduce_from_others([], _).
reduce_from_others([X|Xs], Dom) :-
        (   fd_get(X, XDom, XPs) ->
            domain_subtract(XDom, Dom, NXDom),
            fd_put(X, NXDom, XPs)
        ;   true
        ),
        reduce_from_others(Xs, Dom).

num_subsets([], _Dom, Num, Num, []).
num_subsets([S|Ss], Dom, Num0, Num, NonSubs) :-
        (   fd_get(S, SDom, _) ->
            (   domain_subdomain(Dom, SDom) ->
                Num1 is Num0 + 1,
                num_subsets(Ss, Dom, Num1, Num, NonSubs)
            ;   NonSubs = [S|Rest],
                num_subsets(Ss, Dom, Num0, Num, Rest)
            )
        ;   num_subsets(Ss, Dom, Num0, Num, NonSubs)
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%      serialized(+Starts, +Durations)
%
%       Constrain a set of intervals to a non-overlapping sequence.
%       Starts = [S_1,...,S_n], is a list of variables or integers,
%       Durations = [D_1,...,D_n] is a list of non-negative integers.
%       Constrains Starts and Durations to denote a set of
%       non-overlapping tasks, i.e.: S_i + D_i =< S_j or S_j + D_j =<
%       S_i for all 1 =< i < j =< n.
%
%  @see Dorndorf et al. 2000, "Constraint Propagation Techniques for the
%       Disjunctive Scheduling Problem"

serialized(Starts, Durations) :-
        must_be(list(integer), Durations),
        pair_up(Starts, Durations, SDs),
        serialize(SDs, []),
        do_queue.

pair_up([], [], []).
pair_up([A|As], [B|Bs], [A-n(B)|ABs]) :- pair_up(As, Bs, ABs).

% attribute: pserialized(Var, Duration, Left, Right)
%   Left and Right are lists of Start-Duration pairs representing
%   other tasks occupying the same resource

serialize([], _).
serialize([Start-D|SDs], Left) :-
        cis_geq_zero(D),
        (   var(Start) ->
            make_propagator(pserialized(Start,D,Left,SDs), Prop),
            init_propagator(Start, Prop),
            trigger_prop(Prop)
        ;   true
        ),
        myserialized(D, Left, SDs, Start),
        serialize(SDs, [Start-D|Left]).

% consistency check / propagation
% Currently implements 2-b-consistency

myserialized(Duration, Left, Right, Start) :-
        myserialized(Left, Start, Duration),
        myserialized(Right, Start, Duration).

earliest_start_time(Start, EST) :-
        (   fd_get(Start, D, _) ->
            domain_infimum(D, EST)
        ;   EST = n(Start)
        ).

latest_start_time(Start, LST) :-
        (   fd_get(Start, D, _) ->
            domain_supremum(D, LST)
        ;   LST = n(Start)
        ).

myserialized([], _, _).
myserialized([S_I-D_I|SDs], S_J, D_J) :-
        (   var(S_I) ->
            serialize_lower_bound(S_I, D_I, Start, D_J),
            (   var(S_I) -> serialize_upper_bound(S_I, D_I, Start, D_J)
            ;   true
            )
        ;   var(S_J) ->
            serialize_lower_bound(S_J, D_J, S, D_I),
            (   var(S_J) -> serialize_upper_bound(S_J, D_J, S, D_I)
            ;   true
            )
        ;   D_I = n(D_II), D_J = n(D_JJ),
            (   S_I + D_II =< S_J -> true
            ;   S_J + D_JJ =< S_I -> true
            ;   fail
            )
        ),
        myserialized(SDs, S_J, D_J).

serialize_lower_bound(I, D_I, J, D_J) :-
        fd_get(I, DomI, Ps),
        domain_infimum(DomI, EST_I),
        latest_start_time(J, LST_J),
        (   Sum cis EST_I + D_I, Sum cis_gt LST_J ->
            earliest_start_time(J, EST_J),
            EST cis EST_J+D_J,
            domain_remove_smaller_than(DomI, EST, DomI1),
            fd_put(I, DomI1, Ps)
        ;   true
        ).

serialize_upper_bound(I, D_I, J, D_J) :-
        fd_get(I, DomI, Ps),
        domain_supremum(DomI, LST_I),
        earliest_start_time(J, EST_J),
        (   Sum cis EST_J + D_J, Sum cis_gt LST_I ->
            latest_start_time(J, LST_J),
            LST cis LST_J-D_I,
            domain_remove_greater_than(DomI, LST, DomI1),
            fd_put(I, DomI1, Ps)
        ;   true
        ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%    element(?N, +Is, ?I)
%
%     The N-th element of the list of integers Is is I. Analogous to nth1/3.

element(N, Is, I) :-
        must_be(list, Is),
        length(Is, L),
        numlist(1, L, Ns),
        maplist(twolist, Ns, Is, Rs),
        tuples_in([[N,I]], Rs).

twolist(N, I, [N,I]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% zcompare(?Order, ?A, ?B)
%
% Analogous to compare/3, with finite domain variables A and B.
% Example:
%
% ==
%  fac(N, F) :-
%          zcompare(C, N, 0),
%          fac_(C, N, F).
%
%  fac_(=, _, 1).
%  fac_(>, N, F) :- F #= F0*N, N1 #= N - 1, fac(N1, F0).
% ==
%
% This version is deterministic if the first argument is instantiated:
%
% ==
% ?- fac(30, F).
% F = 265252859812191058636308480000000.
% ==

zcompare(Order, A, B) :-
        (   nonvar(Order) ->
            zcompare_(Order, A, B)
        ;   freeze(Order, zcompare_(Order, A, B)),
            fd_variable(A),
            fd_variable(B),
            propagator_init_trigger(pzcompare(Order, A, B))
        ).

zcompare_(=, A, B) :- A #= B.
zcompare_(<, A, B) :- A #< B.
zcompare_(>, A, B) :- A #> B.

%% chain(+Zs, +Relation)
%
% Zs is a list of finite domain variables that are a chain with
% respect to the partial order Relation, in the order they appear in
% the list. Relation must be #=, #=<, #>=, #< or #>. For example:
%
% ==
% ?- chain([X,Y,Z], #>=).
% X#>=Y,
% Y#>=Z.
% ==

chain(Zs, Relation) :-
        must_be(list, Zs),
        maplist(fd_variable, Zs),
        must_be(ground, Relation),
        (   chain_relation(Relation) -> true
        ;   domain_error(chain_relation, Relation)
        ),
        (   Zs = [] -> true
        ;   Zs = [X|Xs],
            chain(Xs, X, Relation)
        ).

chain_relation(#=).
chain_relation(#<).
chain_relation(#=<).
chain_relation(#>).
chain_relation(#>=).

chain([], _, _).
chain([X|Xs], Prev, Relation) :-
        call(Relation, Prev, X),
        chain(Xs, X, Relation).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Reflection predicates
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

%% fd_var(+Var)
%
%  True iff Var is a CLP(FD) variable.

fd_var(X) :- get_attr(X, clpfd, _).

%% fd_inf(+Var, -Inf)
%
%  Inf is the infimum of the current domain of Var.

fd_inf(X, Inf) :-
        (   fd_get(X, XD, _) ->
            domain_infimum(XD, Inf0),
            bound_portray(Inf0, Inf)
        ;   must_be(integer, X),
            Inf = X
        ).

%% fd_sup(+Var, -Sup)
%
%  Sup is the supremum of the current domain of Var.

fd_sup(X, Sup) :-
        (   fd_get(X, XD, _) ->
            domain_supremum(XD, Sup0),
            bound_portray(Sup0, Sup)
        ;   must_be(integer, X),
            Sup = X
        ).

%% fd_size(+Var, -Size)
%
%  Size is the number of elements of the current domain of Var, or the
%  atom *sup* if the domain is unbounded.

fd_size(X, S) :-
        (   fd_get(X, XD, _) ->
            domain_num_elements(XD, S0),
            bound_portray(S0, S)
        ;   must_be(integer, X),
            S = 1
        ).

%% fd_dom(+Var, -Dom)
%
%  Dom is the current domain (see in/2) of Var. This predicate is
%  useful if you want to reason about domains. It is not needed if you
%  only want to display remaining domains; instead, separate your
%  model from the search part and let the toplevel display this
%  information via residual goals.

fd_dom(X, Drep) :-
        (   fd_get(X, XD, _) ->
            domain_to_drep(XD, Drep)
        ;   must_be(integer, X),
            Drep = X..X
        ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Entailment detection. Subject to change.

   Currently, Goals entail E if posting ({#\ E} U Goals), then
   labeling all variables, fails. E must be reifiable. Examples:

   %?- clpfd:goals_entail([X#>2], X #> 3).
   %@ false.

   %?- clpfd:goals_entail([X#>1, X#<3], X #= 2).
   %@ true.

   %?- clpfd:goals_entail([X#=Y+1], X #= Y+1).
   %@ ERROR: Arguments are not sufficiently instantiated
   %@    Exception: (15) throw(error(instantiation_error, _G2680)) ?

   %?- clpfd:goals_entail([[X,Y] ins 0..10, X#=Y+1], X #= Y+1).
   %@ true.

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

goals_entail(Goals, E) :-
        must_be(list, Goals),
        \+ (   maplist(call, Goals), #\ E,
               term_variables(Goals-E, Vs),
               label(Vs)
           ).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Unification hook and constraint projection
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

attr_unify_hook(clpfd_attr(_,_,_,Dom,Ps), Other) :-
        (   nonvar(Other) ->
            (   integer(Other) -> true
            ;   type_error(integer, Other)
            ),
            domain_contains(Dom, Other),
            trigger_props(Ps),
            do_queue
        ;   fd_get(Other, OD, OPs),
            domains_intersection(OD, Dom, Dom1),
            append_propagators(Ps, OPs, Ps1),
            fd_put(Other, Dom1, Ps1),
            trigger_props(Ps1),
            do_queue
        ).

append_propagators(fd_props(Gs0,Bs0,Os0), fd_props(Gs1,Bs1,Os1), fd_props(Gs,Bs,Os)) :-
        append(Gs0, Gs1, Gs),
        append(Bs0, Bs1, Bs),
        append(Os0, Os1, Os).

bound_portray(inf, inf).
bound_portray(sup, sup).
bound_portray(n(N), N).

domain_to_drep(Dom, Drep) :-
        domain_intervals(Dom, [A0-B0|Rest]),
        bound_portray(A0, A),
        bound_portray(B0, B),
        (   A == B -> Drep0 = A
        ;   Drep0 = A..B
        ),
        intervals_to_drep(Rest, Drep0, Drep).

intervals_to_drep([], Drep, Drep).
intervals_to_drep([A0-B0|Rest], Drep0, Drep) :-
        bound_portray(A0, A),
        bound_portray(B0, B),
        (   A == B -> D1 = A
        ;   D1 = A..B
        ),
        intervals_to_drep(Rest, Drep0 \/ D1, Drep).

attribute_goals(X) -->
        % { get_attr(X, clpfd, Attr), format("A: ~w\n", [Attr]) },
        { get_attr(X, clpfd, clpfd_attr(_,_,_,Dom,fd_props(Gs,Bs,Os))),
          append(Gs, Bs, Ps0),
          append(Ps0, Os, Ps),
          domain_to_drep(Dom, Drep) },
        (   { default_domain(Dom), \+ all_dead_(Ps) } -> []
        ;   [clpfd:(X in Drep)]
        ),
        attributes_goals(Ps).

clpfd_aux:attribute_goals(_) --> [].
clpfd_aux:attr_unify_hook(_,_) :- fail.

attributes_goals([]) --> [].
attributes_goals([propagator(P, State)|As]) -->
        (   { ground(State) } -> []
        ;   { ( functor(P, pdifferent, _) ; functor(P, pdistinct, _) ),
              arg(4, P, S), S == processed } -> []
        ;   { phrase(attribute_goal_(P), Gs) } ->
            { del_attr(State, clpfd_aux), State = processed },
            with_clpfd(Gs)
        ;   [P] % possibly user-defined constraint
        ),
        attributes_goals(As).

with_clpfd([])     --> [].
with_clpfd([G|Gs]) --> [clpfd:G], with_clpfd(Gs).

attribute_goal_(presidual(Goal))       --> [Goal].
attribute_goal_(pgeq(A,B))             --> [A #>= B].
attribute_goal_(pplus(X,Y,Z))          --> [X + Y #= Z].
attribute_goal_(pneq(A,B))             --> [A #\= B].
attribute_goal_(ptimes(X,Y,Z))         --> [X*Y #= Z].
attribute_goal_(absdiff_neq(X,Y,C))    --> [abs(X-Y) #\= C].
attribute_goal_(absdiff_geq(X,Y,C))    --> [abs(X-Y) #>= C].
attribute_goal_(x_neq_y_plus_z(X,Y,Z)) --> [X #\= Y + Z].
attribute_goal_(x_leq_y_plus_c(X,Y,C)) --> [X #=< Y + C].
attribute_goal_(pdiv(X,Y,Z))           --> [X/Y #= Z].
attribute_goal_(pexp(X,Y,Z))           --> [X^Y #= Z].
attribute_goal_(pabs(X,Y))             --> [Y #= abs(X)].
attribute_goal_(pmod(X,M,K))           --> [X mod M #= K].
attribute_goal_(pmax(X,Y,Z))           --> [Z #= max(X,Y)].
attribute_goal_(pmin(X,Y,Z))           --> [Z #= min(X,Y)].
attribute_goal_(scalar_product_neq([FC|Cs],[FV|Vs],C)) -->
        [Left #\= C],
        { coeff_var_term(FC, FV, T0), fold_product(Cs, Vs, T0, Left) }.
attribute_goal_(scalar_product_eq([FC|Cs],[FV|Vs],C)) -->
        [Left #= C],
        { coeff_var_term(FC, FV, T0), fold_product(Cs, Vs, T0, Left) }.
attribute_goal_(pdifferent(Left, Right, X, processed)) -->
        [all_different(Vs)],
        { append(Left, [X|Right], Vs0), msort(Vs0, Vs) }.
attribute_goal_(pdistinct(Left, Right, X, processed)) -->
        [all_distinct(Vs)],
        { append(Left, [X|Right], Vs0), msort(Vs0, Vs) }.
attribute_goal_(pserialized(Var,D,Left,Right)) -->
        [serialized(Vs, Ds)],
        { append(Left, [Var-D|Right], VDs), pair_up(Vs, Ds, VDs) }.
attribute_goal_(rel_tuple(mutable(Rel,_), Tuple)) --> [tuples_in([Tuple], Rel)].
attribute_goal_(pzcompare(O,A,B)) --> [zcompare(O,A,B)].
% reified constraints
attribute_goal_(reified_in(V, D, B)) -->
        [V in Drep #<==> B],
        { domain_to_drep(D, Drep) }.
attribute_goal_(reified_fd(V,B)) --> [finite_domain(V) #<==> B].
attribute_goal_(reified_neq(DX,X,DY,Y,_,B)) --> conjunction(DX, DY, X#\=Y, B).
attribute_goal_(reified_eq(DX,X,DY,Y,_,B))  --> conjunction(DX, DY, X #= Y, B).
attribute_goal_(reified_geq(DX,X,DY,Y,_,B)) --> conjunction(DX, DY, X #>= Y, B).
attribute_goal_(reified_div(X,Y,D,_,Z)) -->
        [D #= 1 #==> X / Y #= Z, Y #\= 0 #==> D #= 1].
attribute_goal_(reified_mod(X,Y,D,_,Z)) -->
        [D #= 1 #==> X mod Y #= Z, Y #\= 0 #==> D #= 1].
attribute_goal_(reified_and(X,_,Y,_,B))    --> [X #/\ Y #<==> B].
attribute_goal_(reified_or(X, _, Y, _, B)) --> [X #\/ Y #<==> B].
attribute_goal_(reified_not(X, Y))         --> [#\ X #<==> Y].
attribute_goal_(pimpl(X, Y, _))            --> [X #==> Y].

conjunction(A, B, G, D) -->
        (   { A == 1, B == 1 } -> [G #<==> D]
        ;   { A == 1 } -> [(B #/\ G) #<==> D]
        ;   { B == 1 } -> [(A #/\ G) #<==> D]
        ;   [(A #/\ B #/\ G) #<==> D]
        ).

coeff_var_term(C, V, T) :- ( C =:= 1 -> T = V ; T = C*V ).

fold_product([], [], P, P).
fold_product([C|Cs], [V|Vs], P0, P) :-
        coeff_var_term(C, V, T),
        fold_product(Cs, Vs, P0 + T, P).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% /* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%    Testing
% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */


% domain_to_list(Domain, List) :- phrase(domain_to_list(Domain), List).

% domain_to_list(split(_, Left, Right)) -->
%         domain_to_list(Left), domain_to_list(Right).
% domain_to_list(empty)                 --> [].
% domain_to_list(from_to(n(F),n(T)))    --> { numlist(F, T, Ns) }, dlist(Ns).

% dlist([])     --> [].
% dlist([L|Ls]) --> [L], dlist(Ls).

% %?- test_intersection([1,2,3,4,5], [1,5], I).

% %?- test_intersection([1,2,3,4,5], [], I).

% test_intersection(List1, List2, Is) :-
%         list_to_domain(List1, D1),
%         list_to_domain(List2, D2),
%         domains_intersection(D1, D2, I),
%         domain_to_list(I, Is).

% test_subdomain(L1, L2) :-
%         list_to_domain(L1, D1),
%         list_to_domain(L2, D2),
%         domain_subdomain(D1, D2).

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Generated predicates
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

term_expansion(make_parse_clpfd, Clauses)   :- make_parse_clpfd(Clauses).
term_expansion(make_parse_reified, Clauses) :- make_parse_reified(Clauses).
term_expansion(make_matches, Clauses)       :- make_matches(Clauses).

make_parse_clpfd.
make_parse_reified.
make_matches.

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Global variables
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

make_clpfd_var('$clpfd_queue') :-
        make_queue.
make_clpfd_var('$clpfd_current_propagator') :-
        nb_setval('$clpfd_current_propagator', []).
make_clpfd_var('$clpfd_queue_status') :-
        nb_setval('$clpfd_queue_status', enabled).

:- multifile user:exception/3.

user:exception(undefined_global_variable, Name, retry) :-
        make_clpfd_var(Name), !.

warn_if_bounded_arithmetic :-
        (   current_prolog_flag(bounded, true) ->
            print_message(warning, clpfd(bounded))
        ;   true
        ).

:- initialization(warn_if_bounded_arithmetic).


/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   Messages
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

:- multifile prolog:message//1.

prolog:message(clpfd(bounded)) -->
        ['Using CLP(FD) with bounded arithmetic may yield wrong results.'-[]].
