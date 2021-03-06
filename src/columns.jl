# a type that stores an array of tuples as a tuple of arrays

using Compat

import Base:
    linearindexing, push!, size, sort, sort!, permute!, issorted, sortperm,
    summary, resize!, vcat, serialize, deserialize, append!, copy!

export Columns

struct Columns{D<:Tup, C<:Tup} <: AbstractVector{D}
    columns::C

    function Columns{D,C}(c) where {D<:Tup,C<:Tup}
        length(c) > 0 || error("must have at least one column")
        n = length(c[1])
        for i = 2:length(c)
            length(c[i]) == n || error("all columns must have same length")
        end
        new{D,C}(c)
    end
end

function Columns(cols::AbstractVector...; names::Union{Vector{Symbol},Tuple{Vararg{Symbol}},Void}=nothing)
    if isa(names, Void)
        Columns{eltypes(typeof(cols)),typeof(cols)}(cols)
    else
        dt = eval(:(@NT($(names...)))){map(eltype, cols)...}
        ct = eval(:(@NT($(names...)))){map(typeof, cols)...}
        Columns{dt,ct}(ct(cols...))
    end
end

Columns(; pairs...) = Columns(map(x->x[2],pairs)..., names=Symbol[x[1] for x in pairs])

Columns(c::Tup) = Columns{eltypes(typeof(c)),typeof(c)}(c)

eltype{D,C}(::Type{Columns{D,C}}) = D
length(c::Columns) = length(c.columns[1])
ndims(c::Columns) = 1
size(c::Columns) = (length(c),)
Base.IndexStyle(::Type{<:Columns}) = IndexLinear()
summary(c::Columns{D}) where {D<:Tuple} = "Columns{$D}"

empty!(c::Columns) = (foreach(empty!, c.columns); c)
similar(c::Columns{D,C}) where {D,C} = Columns{D,C}(map(similar, c.columns))
similar(c::Columns{D,C}, n::Integer) where {D,C} = Columns{D,C}(map(a->similar(a,n), c.columns))
function Base.similar{T<:Columns}(::Type{T}, n::Int)::T
    T_cols = T.parameters[2]
    f = T_cols <: Tuple ? tuple : T_cols
    T(f(map(t->similar(t, n), T.parameters[2].parameters)...))
end

function convert{N}(::Type{Columns}, x::AbstractArray{<:NTuple{N,Any}})
    eltypes = (eltype(x).parameters...)
    copy!(Columns(map(t->Vector{t}(length(x)), eltypes)), x)
end

function convert(::Type{Columns}, x::AbstractArray{<:NamedTuple})
    eltypes = (eltype(x).parameters...)
    copy!(Columns(map(t->Vector{t}(length(x)), eltypes)..., names=fieldnames(eltype(x))), x)
end


getindex(c::Columns{D}, i::Integer) where {D<:Tuple} = ith_all(i, c.columns)
getindex(c::Columns{D}, i::Integer) where {D<:NamedTuple} = D(ith_all(i, c.columns)...)

getindex(c::Columns{D,C}, p::AbstractVector) where {D,C} = Columns{D,C}(map(c->c[p], c.columns))

@inline setindex!(I::Columns, r::Tup, i::Integer) = (foreach((c,v)->(c[i]=v), I.columns, r); I)

@inline push!(I::Columns, r::Tup) = (foreach(push!, I.columns, r); I)

append!(I::Columns, J::Columns) = (foreach(append!, I.columns, J.columns); I)

copy!(I::Columns, J::Columns) = (foreach(copy!, I.columns, J.columns); I)

resize!(I::Columns, n::Int) = (foreach(c->resize!(c,n), I.columns); I)

_sizehint!(c::Columns, n::Integer) = (foreach(c->_sizehint!(c,n), c.columns); c)

function ==(x::Columns, y::Columns)
    nc = length(x.columns)
    length(y.columns) == nc || return false
    fieldnames(eltype(x)) == fieldnames(eltype(y)) || return false
    n = length(x)
    length(y) == n || return false
    for i in 1:nc
        x.columns[i] == y.columns[i] || return false
    end
    return true
end

sortproxy(x::PooledArray) = x.refs
sortproxy(x::AbstractArray) = x

function sortperm(c::Columns)
    cols = c.columns
    x = cols[1]
    p = sortperm_fast(x)
    if length(cols) > 1
        y = cols[2]
        refine_perm!(p, cols, 1, x, sortproxy(y), 1, length(x))
    end
    return p
end

issorted(c::Columns) = issorted(1:length(c), lt=(x,y)->rowless(c, x, y))

# assuming x[p] is sorted, sort by remaining columns where x[p] is constant
function refine_perm!(p, cols, c, x, y, lo, hi)
    temp = similar(p, 0)
    order = Base.Order.By(j->(@inbounds k=y[j]; k))
    nc = length(cols)
    i = lo
    while i < hi
        i1 = i+1
        @inbounds while i1 <= hi && roweq(x, p[i1], p[i])
            i1 += 1
        end
        i1 -= 1
        if i1 > i
            sort_sub_by!(p, i, i1, y, order, temp)
            if c < nc-1
                z = cols[c+2]
                refine_perm!(p, cols, c+1, y, sortproxy(z), i, i1)
            end
        end
        i = i1+1
    end
end

function permute!(c::Columns, p::AbstractVector)
    for v in c.columns
        copy!(v, v[p])
    end
    return c
end
sort!(c::Columns) = permute!(c, sortperm(c))
sort(c::Columns) = c[sortperm(c)]

map(p::ProjFn, c::Columns) = Columns(p(c.columns))
map(p::Proj, c::Columns) = p(c.columns)

vcat(c::Columns{D,C}, cs::Columns{D,C}...) where {D<:Tup,C<:Tuple} = Columns{D,C}((map(vcat, map(x->x.columns, (c,cs...))...)...,))
vcat(c::Columns{D,C}, cs::Columns{D,C}...) where {D<:Tup,C<:NamedTuple} = Columns{D,C}(C(map(vcat, map(x->x.columns, (c,cs...))...)...,))

function Base.vcat(c::Columns, cs::Columns...)
    fns = map(fieldnames, (map(x->x.columns, (c, cs...))))
    f1 = fns[1]
    for f2 in fns[2:end]
        if f1 != f2
            errfields = join(map(string, fns), ", ", " and ")
            throw(ArgumentError("Cannot concatenate columns with fields $errfields"))
        end
    end
    Columns(map(vcat, map(x->x.columns, (c,cs...))...))
end

abstract type SerializedColumns end

function serialize(s::AbstractSerializer, c::Columns)
    Base.Serializer.serialize_type(s, SerializedColumns)
    serialize(s, eltype(c) <: NamedTuple)
    serialize(s, isa(c.columns, NamedTuple))
    serialize(s, fieldnames(c.columns))
    for col in c.columns
        serialize(s, col)
    end
end

function deserialize(s::AbstractSerializer, ::Type{SerializedColumns})
    Dnamed = deserialize(s)
    Cnamed = deserialize(s)
    fn = deserialize(s)
    cols = Any[ deserialize(s) for i = 1:length(fn) ]
    if Cnamed
        c = Columns(cols..., names = fn)
        if !Dnamed
            dt = eltypes(typeof((c.columns...,)))
            c = Columns{dt,typeof(c.columns)}(c.columns)
        end
    else
        c = Columns(cols...)
    end
    return c
end

# fused indexing operations
# these can be implemented for custom vector types like PooledVector where
# you can get big speedups by doing indexing and an operation in one step.

@inline cmpelts(a, i, j) = (@inbounds x=cmp(a[i], a[j]); x)
@inline copyelt!(a, i, j) = (@inbounds a[i] = a[j])
@inline copyelt!(a, i, b, j) = (@inbounds a[i] = b[j])

@inline cmpelts(a::PooledArray, i, j) = (x=cmp(a.refs[i],a.refs[j]); x)
@inline copyelt!(a::PooledArray, i, j) = (a.refs[i] = a.refs[j])

# row operations

copyrow!(I::Columns, i, src) = foreach(c->copyelt!(c, i, src), I.columns)
copyrow!(I::Columns, i, src::Columns, j) = foreach((c1,c2)->copyelt!(c1, i, c2, j), I.columns, src.columns)
copyrow!(I::AbstractArray, i, src::AbstractArray, j) = (@inbounds I[i] = src[j])
pushrow!(to::Columns, from::Columns, i) = foreach((a,b)->push!(a, b[i]), to.columns, from.columns)

@generated function rowless{D,C}(c::Columns{D,C}, i, j)
    N = length(C.parameters)
    ex = :(cmpelts(getfield(c.columns,$N), i, j) < 0)
    for n in N-1:-1:1
        ex = quote
            let d = cmpelts(getfield(c.columns,$n), i, j)
                (d == 0) ? ($ex) : (d < 0)
            end
        end
    end
    ex
end

@generated function roweq{D,C}(c::Columns{D,C}, i, j)
    N = length(C.parameters)
    ex = :(cmpelts(getfield(c.columns,1), i, j) == 0)
    for n in 2:N
        ex = :(($ex) && (cmpelts(getfield(c.columns,$n), i, j)==0))
    end
    ex
end

@inline roweq(x::AbstractVector, i, j) = x[i] == x[j]

# uses number of columns from `d`, assuming `c` has more or equal
# dimensions, for broadcast joins.
@generated function rowcmp{D}(c::Columns, i, d::Columns{D}, j)
    N = length(D.parameters)
    ex = :(cmp(getfield(c.columns,$N)[i], getfield(d.columns,$N)[j]))
    for n in N-1:-1:1
        ex = quote
            let k = cmp(getfield(c.columns,$n)[i], getfield(d.columns,$n)[j])
                (k == 0) ? ($ex) : k
            end
        end
    end
    ex
end

# test that the row on the right is "as of" the row on the left, i.e.
# all columns are equal except left >= right in last column.
# Could be generalized to some number of trailing columns, but I don't
# know whether that has applications.
@generated function row_asof{D,C}(c::Columns{D,C}, i, d::Columns{D,C}, j)
    N = length(C.parameters)
    if N == 1
        ex = :(!isless(getfield(c.columns,1)[i], getfield(d.columns,1)[j]))
    else
        ex = :(isequal(getfield(c.columns,1)[i], getfield(d.columns,1)[j]))
    end
    for n in 2:N
        if N == n
            ex = :(($ex) && !isless(getfield(c.columns,$n)[i], getfield(d.columns,$n)[j]))
        else
            ex = :(($ex) && isequal(getfield(c.columns,$n)[i], getfield(d.columns,$n)[j]))
        end
    end
    ex
end
