using RealTimeScheduling
using DataStructures

"""
    schedule_xghtc(constraints, H; slotsize=1, work_conserving=false)

Generate a schedule for a set of weakly hard constraints. The schedule returned has the 
type Matrix{<:Integer}, where the first dimension iterates through tasks, and the second
through time slots. If no safe schedule can be found, an empty Matrix{<:Integer} is returned.
If the schedule returned is shorter than then time horizon H, it means the schedule is
to be repeated and the system will still be safe until H.

The schedule assumes that all tasks are synchronous and have equal periods. At most 
`slotsize` tasks may be scheduled in a single period. The schedule has total length `H`
periods, or it can be shorter if a cycle is found.

Shengjie Xu, Bineet Ghosh, Clara Hobbs, P.S. Thiagarajan, and Samarjit Chakraborty, 
"Safety-Aware Flexible Schedule Synthesis for Cyber-Physical Systems using Weakly-Hard 
Constraints." 
ASPDAC 2023. 
DOI: [10.1145/3566097.3567848](https://doi.org/10.1145/3566097.3567848)
"""
function schedule_xghtc(constraints::Vector{<:MeetAny}, H::Integer;
        slotsize::Integer=1, work_conserving::Bool=false)
    # Check if "utilization" is greater than available slot size
    utilization = sum(c -> c.meet/c.window, constraints)
    if utilization > slotsize
        return Vector{Vector{Int64}}()
    end

    # Create the scheduler automaton from individual constraints
    controllers = _ConstraintAutomaton.(constraints)
    AS = _SynthesizedAutomaton(controllers, slotsize=slotsize, work_conserving=work_conserving)

    # Initialize the list of current states from the initial state of
    # scheduler automaton
    current_states = Dict{Int64, LinkedList{Int64}}(AS.l_0 => list(AS.l_0))

    # Traverse the automaton until 
    #   (1) the required number of steps is reached,
    #   (2) a cycle is found, or 
    #   (3) no more states are valid for exploration
    for step in 1:H
        next_states = Dict{Int64, LinkedList{Int64}}()
        for (l, path) in pairs(current_states), σ in AS.Σ
            l_new = AS.T(l, σ)
            if !AS.Q_f(l_new) || haskey(next_states, l_new)
                continue
            elseif l_new in path
                # Found cycle -> Case (2)
                return _path_to_schedule(reverse(cons(l_new, path)), AS)
            end
            next_states[l_new] = cons(l_new, path)
        end

        if isempty(next_states)
            # No more valid states -> Case (3)
            return zeros(Int64, 0, 0)
        end

        current_states = next_states
    end

    for (l, path) in pairs(current_states)
        if AS.Q_f(l)
            # If the outer loop ends and accepting state is found -> Case (1)
            return _path_to_schedule(reverse(path), AS)
        end
    end

    # If the outer loop ends and accepting state is not found -> Case (1)
    return zeros(Int64, 0, 0)
end

"""
    schedule_xghtc(allconstraints, H; slotsize=1, work_conserving=false)

Given a list of safe constraints for each system, synthesize a schedule using one safe 
constraint from each list. The first successful synthesis result is returned.
"""
function schedule_xghtc(allconstraints::Vector{<:Vector{<:MeetAny}}, H::Integer;
        slotsize::Integer=1, work_conserving::Bool=false)
    for constraints in Iterators.product(allconstraints...)
        sch = schedule_xghtc(collect(constraints), H, 
            slotsize=slotsize, work_conserving=work_conserving)
        if length(sch) > 0
            println(constraints)
            return sch
        end
    end
    return zeros(Int64, 0, 0)
end

"""
    verify_schedule(sysd, K, z_0, σ)

Given a discrete state-space model, feedback gain, the initial state, and a sequence of
deadline hits and misses, returns the maximum deviaiton between the resulting trajectory
and the nominal trajectory for that system where all deadlines are met.
"""
function verify_schedule(sysd::AbstractStateSpace{<:Discrete}, 
        K::AbstractMatrix{<:Real}, z_0::AbstractVecOrMat, σ::AbstractVector{<:Integer})
    a = hold_kill(sysd, K)

    # Convert the actions σ to: 1=hit, 2=miss (instead of 0=miss)
    σ = [i == 0 ? 2 : 1 for i in σ]
    z = evol(a, z_0, σ)

    # Convert trajectory to reachable sets by repeating the state twice for min/max
    reachable = cat(z, z, dims=3)
    maximum(deviation(a, z_0, reachable))
end

"""
    schedule_to_sequence(schedule, task, H)

Given a schedule in the matrix form, the position of the task in the schedule and the desired
length of the sequence, returns a sequence of 0s and 1s of length H representing the deadline
hits and misses for that task under the given schedule.
"""
function schedule_to_sequence(schedule::Matrix{<:Integer}, task::Integer, H::Integer)
    σ = schedule[task, :]
    [repeat(σ, H ÷ length(σ)); σ[1:H % length(σ)]]
end

"""
    synthesize_constraints(sysd, K, z_0, d_max, maxwindow, n, t)

Find all `MeetAny` weakly hard constraints with window size at most `maxwindow` that 
guarantees the deviation upper bound is at most `d_max`. The system is specified by 
[`Automaton`](@ref) `a` and initial state is `z_0`. `n` and `t` are as in 
[`bounded_runs_iter`](@ref).
"""
function synthesize_constraints(sysd::AbstractStateSpace{<:Discrete},
        K::AbstractMatrix{<:Real}, z_0::AbstractVecOrMat, d_max::Real,
        maxwindow::Integer, n::Integer, H::Integer; fullresults=false)

    devs = fill(Inf, maxwindow, maxwindow)
    safe_constraints = [MeetAny(1, 1)]

    if fullresults
        for window = 1:maxwindow, meet=1:window
            devs[window, meet] = devub(meet, window, sysd, K, z_0, d_max, n, H)
            if devs[window, meet] <= d_max && meet < window
                push!(safe_constraints, MeetAny(meet, window))
            end
        end
    else
        # Do not need to go through all O(maxwindow^2) constraints,
        # see paper for optimization argument
        meet = 1
        for window in 1:maxwindow
            while meet <= window
                devs[window, meet] = devub(meet, window, sysd, K, z_0, d_max, n, H)
                if devs[window, meet] <= d_max
                    # All constraints with (m, window) where m >= meet are valid
                    for i in meet:window-1
                        push!(safe_constraints, MeetAny(i, window))
                    end
                    break
                end
                meet += 1
            end
        end
    end

    safe_constraints, devs
end

"""
    devub(meet, window, sysd, K, z_0, d_max, n, H)

Compute the deviation upper bound for a given system under the weakly hard constraint 
(meet, window), over a specified time horizon.
"""
function devub(meet::Integer, window::Integer, sysd::AbstractStateSpace{<:Discrete},
        K::AbstractMatrix{<:Real}, z_0::AbstractVecOrMat, d_max::Real, n::Integer,
        H::Integer)
    if meet == window
        return 0.
    end
    constraint = MeetAny(meet, window)
    a = hold_kill(sysd, K, constraint)
    reachable = bounded_runs_iter(a, z_0, n, ceil(Int64, H/n), safety_margin=d_max)
    reachable = reachable[1:min(H, size(reachable, 1)), :, :]
    # @info "Data" meet window size(reachable, 1) argmax(deviation(a, z_0, reachable))
    maximum(deviation(a, z_0, reachable))
end

"""
    estimate_constraints(sysd, K, z_0, d_max, maxwindow, c, B, H)

Find all `MeetAny` weakly hard constraints with window size at most `maxwindow` that 
guarantees the deviation upper bound is at most `d_max`. The system is specified by 
[`Automaton`](@ref) `a` and initial state is `z_0`. This function uses SHT for 
estimating the deviation upper bound as in [`estimate_deviation`](@ref).
"""
function estimate_constraints(sysd::AbstractStateSpace{<:Discrete},
        K::AbstractMatrix{<:Real}, z_0::AbstractVecOrMat, d_max::Real, 
        maxwindow::Integer, c::Real, B::Real, H::Integer)

    devs = fill(Inf, maxwindow, maxwindow)
    safe_constraints = [MeetAny(1, 1)]
    
    # meet = 1
    for window in 1:maxwindow
        # while meet < window
        for meet in 1:window
            constraint = MeetAny(meet, window)
            a = hold_kill(sysd, K, constraint)
            sampler = SamplerUniformMeetAny(constraint, H)
            m = estimate_deviation(a, sampler, z_0, c, B)
            devs[window, meet] = round(m, sigdigits=4)
            if m <= d_max
                for i in meet:window-1
                    push!(safe_constraints, MeetAny(i, window))
                end
                break
            end
            meet += 1
        end
    end
    
    # display(devs)
    safe_constraints, devs
end

# Helper functions

"""
    _undigit(d[, base=2])

Convert a list of digits to a number. Default base=2.
```jldoctest
julia> ControlTimingSafety._undigit([1, 0, 0])
4
```
"""
function _undigit(d::Vector{<:Integer}; base=2)
    s = 0
    mult = 1
    for val in reverse(d)
        s += val * mult
        mult *= base
    end
    return s
end

"""
    _digits_b2r(x[, pad])

Digits **b**ase **2**, **r**everse
A shortcut for `digits(x, base=2, pad=pad) |> reverse`
"""
_digits_b2r(x::Integer; pad::Integer=0) = digits(x, base=2, pad=pad) |> reverse

"""
    _state_separation(l, B[, indigits=false])

_state_separation takes a number `l` representing the overall state of
a `_SynthesizedAutomaton` and an array `B` representing the number of bits
for each comprising `Automaton` of the `_SynthesizedAutomaton` to compute a 
list of individual states. For example

```jldoctest
julia> ControlTimingSafety._state_separation(6, [1, 2])
2-element Vector{<:Integer}:
 1
 2
```
The explanation of the example is as follows
```
6 -> [1, 1, 0]
[1, 1, 0] / [1, 2] -> [[1], [1, 0]]
[[1], [1, 0]] -> [1, 2]
```
"""
function _state_separation(l::Integer, B::Vector{<:Integer}; indigits=false)
    @boundscheck l < 2^sum(B) || throw(ArgumentError("l has more bits than the sum of B"))
    
    bits = digits(l, base=2, pad=sum(B)) |> reverse
    index_points = cumsum(B)
    from_index = [0; index_points[1:end-1]]
    to_index = index_points
    bits_separated = [bits[i+1:j] for (i, j) in zip(from_index, to_index)]
    if indigits
        bits_separated
    else
        map(_undigit, bits_separated)
    end
end

"""
Struct for a controller automaton which enforces only the weakly 
hard constraint for that controller. i.e., it is not concerned with the
dynamical matrix of the system.
"""
struct _ConstraintAutomaton
    # # of locations. Legal locations are in the range 0:L-1.
    L::Int64
    # # of actions. Legal actions are in the range 0:Σ-1.
    Σ::Int64
    # Transition function. T(l,σ) is a location in 0:L-1.
    T::Function
    # Initial location in L.
    l_0::Int64
    # Function that returns whether a location is final
    Q_f::Function
end

"""
Build an constraint controller automaton for the given weakly hard constraint
"""
function _ConstraintAutomaton(c::MeetAny)
    # Define the automaton's structure. State l=0 is the dead state (trapping)
    if c.meet == 0
        # No requirement. Always valid.
        L = 2
        T = (l, σ) -> 1
    elseif c.meet == c.window
        # No misses allowed.
        L = 2
        T = (l, σ) -> l & σ
    else
        # Build full automaton. Dead state is l = 1
        L = 2^c.window
        T = function (l, σ)
            l_new = (l << 1) & (L - 1) | σ
            l == 0 || count_ones(l_new) < c.meet ? 0 : l_new
        end
    end
    
    # Put it all together. Starting position is L-1 since there is no miss from the beginning
    _ConstraintAutomaton(L, 2, T, L-1, !iszero)
end

"""
Struct for a synthesized automaton from multiple constraint automata.
"""
struct _SynthesizedAutomaton
    # # of comprising automata
    N::Int64
    # List of bits for all comprising controllers
    B::Vector{Int64}
    # Locations. Legal locations are in the range 0:L-1.
    L::Int64
    # List of actions.
    Σ::Vector{Int64}
    # Transition function.  T(l,σ) is a location in 0:L-1.
    T::Function
    # Initial location in L.
    l_0::Int64
    # Function that returns whether a location is final.
    Q_f::Function
end

"""
Build a scheduler automaton from a given list of controller automata
"""
function _SynthesizedAutomaton(controllers::Vector{_ConstraintAutomaton}; slotsize::Integer=1, work_conserving::Bool=false)
    # Converting tuple to array with collect()
    N = length(controllers)
    B = map(a -> ceil(Int64, log2(a.L)), controllers) |> collect
    L = 2^sum(B)

    all_actions = 0:2^length(controllers)-1
    if work_conserving
        # Utilize all processing budget in each slot
        Σ = filter(σ -> count_ones(σ) == slotsize, all_actions)
    else
        # Allow the processor to be underutilized
        Σ = filter(σ -> count_ones(σ) <= slotsize, all_actions)
    end

    function T(l::Int, σ::Int)
        @boundscheck l < L || throw(ArgumentError("Illegal location"))
        @boundscheck σ in Σ || throw(ArgumentError("Illegal action"))

        states = _state_separation(l, B)
        actions = _digits_b2r(σ, pad=N)
        new_locations = map((controller, l, σ) -> controller.T(l, σ), 
                            controllers, states, actions)
        new_location_bits = map((l, b) -> _digits_b2r(l, pad=b), new_locations, B)
        result = Iterators.flatten(new_location_bits) |> collect |> _undigit
        result
    end

    function Q_f(l::Int)
        states = _state_separation(l, B);
        all(map((c, l) -> c.Q_f(l), controllers, states))
    end

    _SynthesizedAutomaton(N, B, L, Σ, T, L-1, Q_f)
end

function _path_to_schedule(path::Union{LinkedList{<:Integer}, Vector{<:Integer}}, AS::_SynthesizedAutomaton)
    # Convert path to Vector
    path = collect(path)

    # Find if there is a cycle in path. If so, proceed with only the repeating part.
    index = findfirst(isequal(path[end]), path)
    if index < length(path)
        path = path[index:end]
    end

    # Separate scheduler automaton states to individual controller states.
    states = map(l -> _state_separation(l, AS.B, indigits=true), path)

    # Take the last location of each controller state as the schedule for that slot.
    schedule = map(states[2:end]) do state
        map(controller_state -> controller_state[end], state)
    end

    # Concatenate the schedule into a Matrix.
    reduce(hcat, schedule)
end
