using Base.Broadcast: BroadcastStyle, AbstractArrayStyle, DefaultArrayStyle, Broadcasted

struct StridedArrayStyle{N} <: AbstractArrayStyle{N}
end

Broadcast.BroadcastStyle(::Type{<:AbstractStridedView{<:Any,N}}) where {N} = StridedArrayStyle{N}()

StridedArrayStyle(::Val{N}) where {N} = StridedArrayStyle{N}()
StridedArrayStyle{M}(::Val{N}) where {M,N} = StridedArrayStyle{N}()

Broadcast.BroadcastStyle(a::StridedArrayStyle, ::DefaultArrayStyle{0}) = a
Broadcast.BroadcastStyle(::StridedArrayStyle{N}, a::DefaultArrayStyle) where {N} = BroadcastStyle(DefaultArrayStyle{N}(), a)
Broadcast.BroadcastStyle(::StridedArrayStyle{N}, ::Broadcast.Style{Tuple}) where {N} = DefaultArrayStyle{N}()

function Base.similar(bc::Broadcasted{<:StridedArrayStyle{N}}, eltype::T) where {N,T}
    StridedView(similar(convert(Broadcasted{DefaultArrayStyle{N}}, bc), eltype))
end

Base.dotview(a::AbstractStridedView{<:Any,N}, I::Vararg{Union{RangeIndex,Colon},N}) where {N} = getindex(a, I...)

# Broadcasting implementation
@inline function Base.copyto!(dest::AbstractStridedView{<:Any,N}, bc::Broadcasted{StridedArrayStyle{N}}) where {N}
    # convert to map

    # flatten and only keep the AbstractStridedView arguments
    # promote AbstractStridedView to have same size, by giving artificial zero strides
    stridedargs = promoteshape(size(dest), capturestridedargs(bc)...)
    c = make_capture(bc)
    return map!(c, dest, stridedargs...)
end

const WrappedScalarArgs = Union{AbstractArray{<:Any,0}, Ref{<:Any}}

@inline capturestridedargs(t::Broadcasted, rest...) = (capturestridedargs(t.args...)..., capturestridedargs(rest...)...)
@inline capturestridedargs(t::AbstractStridedView, rest...) = (t, capturestridedargs(rest...)...)
@inline capturestridedargs(t, rest...) = capturestridedargs(rest...)
@inline capturestridedargs() = ()

# broadcast by promoting size 1 dimensions to full size, making the stride in that dimension zero
promoteshape(sz::Dims, a1::AbstractStridedView, As...) = (promoteshape1(sz, a1), promoteshape(sz, As...)...)
promoteshape(sz::Dims) = ()
function promoteshape1(sz::Dims{N}, a::StridedView) where {N}
    newstrides = ntuple(Val(N)) do d
        if size(a, d) == sz[d]
            stride(a, d)
        elseif size(a, d) == 1
            0
        else
            throw(DimensionMismatch("array could not be broadcast to match destination"))
        end
    end
    return StridedView(a.parent, sz, newstrides, a.offset, a.op)
end
function promoteshape1(sz::Dims{N}, a::UnsafeStridedView) where {N}
    newstrides = ntuple(Val(N)) do d
        if size(a, d) == sz[d]
            stride(a, d)
        elseif size(a, d) == 1
            0
        else
            throw(DimensionMismatch("array could not be broadcast to match destination"))
        end
    end
    return UnsafeStridedView(a.ptr, sz, newstrides, a.offset, a.op)
end


struct CaptureArgs{F, Args<:Tuple}
    f::F
    args::Args
end
struct Arg
end

# construct CaptureArgs
@inline function make_capture(bc::Broadcasted)
    args = make_tcapture(bc.args)
    CaptureArgs(bc.f, args)
end
@inline make_tcapture(t::Tuple{}) = t
@inline make_tcapture(t::Tuple) = (make_capture(t[1]), make_tcapture(tail(t))...)
@inline make_capture(a::WrappedScalarArgs) = a[]
@inline make_capture(a::AbstractStridedView) = Arg()
@inline make_capture(a) = a

# Evaluate CaptureArgs
(c::CaptureArgs)(vals...) = consume(c, vals)[1]
@inline function consume(c::CaptureArgs{F,Args}, vals) where {F,Args}
    args, newvals = t_consume(c.args, vals)
    return c.f(args...), newvals
end
@inline consume(a::Arg, vals::Tuple) = vals[1], tail(vals)
@inline consume(a, vals) = a, vals
@inline t_consume(t::Tuple{}, vals) = t, vals
@inline function t_consume(t::Tuple, vals)
    t1, newvals1 = consume(t[1], vals)
    ttail, newvals = t_consume(tail(t), newvals1)
    return (t1, ttail...), newvals
end

# Old broadcasting approach
# function Base.copyto!(dest::AbstractStridedView{<:Any,N}, bc::Broadcasted{StridedArrayStyle{N}}) where {N}
#     # convert to map
#
#     # flatten and only keep the AbstractStridedView arguments
#     # promote AbstractStridedView to have same size, by giving artificial zero strides
#     stridedargs = promoteshape(size(dest), capturestridedargs(bc)...)
#
#     let makeargs = make_makeargs(bc)
#         f = @inline function(args::Vararg{Any,N}) where N
#             bc.f(makeargs(args...)...)
#         end
#         return map!(f, dest, stridedargs...)
#     end
# end

# @inline make_makeargs(bc::Broadcasted) = make_makeargs(()->(), bc.args)
# @inline function make_makeargs(makeargs, t::Tuple{<:AbstractStridedView,Vararg{Any}})
#     let makeargs = make_makeargs(makeargs, tail(t))
#         return @inline function(head, tail::Vararg{Any,N}) where N
#             (head, makeargs(tail...)...)
#         end
#     end
# end
# @inline function make_makeargs(makeargs, t::Tuple{<:WrappedScalarArgs,Vararg{Any}})
#     let makeargs = make_makeargs(makeargs, tail(t))
#         return @inline function(tail::Vararg{Any,N}) where N
#             (t[1][], makeargs(tail...)...)
#         end
#     end
# end
# @inline function make_makeargs(makeargs, t::Tuple{Ref{Type{T}},Vararg{Any}}) where {T}
#     let makeargs = make_makeargs(makeargs, tail(t))
#         return @inline function(tail::Vararg{Any,N}) where N
#             (T, makeargs(tail...)...)
#         end
#     end
# end
# @inline function make_makeargs(makeargs, t::Tuple{<:Any,Vararg{Any}})
#     let makeargs = make_makeargs(makeargs, tail(t))
#         return @inline function(tail::Vararg{Any,N}) where N
#             (t[1], makeargs(tail...)...)
#         end
#     end
# end
# @inline function make_makeargs(makeargs, t::Tuple{<:Broadcasted,Vararg{Any}})
#     bc = t[1]
#     let makeargs = make_makeargs(makeargs, tail(t))
#         let makeargs = make_makeargs(makeargs, bc.args)
#             headargs, tailargs = Broadcast.make_headargs(bc.args), Broadcast.make_tailargs(bc.args)
#             return @inline function(args::Vararg{Any,N}) where N
#                 args1 = makeargs(args...)
#                 a, b = headargs(args1...), tailargs(args1...)
#                 (bc.f(a...), b...)
#             end
#         end
#     end
# end
# @inline make_makeargs(makeargs, ::Tuple{}) = makeargs