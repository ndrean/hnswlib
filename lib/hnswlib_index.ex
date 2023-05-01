defmodule HNSWLib.Index do
  @moduledoc """
  Documentation for `HNSWLib.Index`.
  """

  defstruct [:space, :dim, :pid]
  alias __MODULE__, as: T
  alias HNSWLib.Helper

  use GenServer

  @doc """
  Construct a new Index

  ##### Positional Parameters

  - *space*: `:cosine` | `:ip` | `:l2`.

    An atom that indicates the vector space. Valid values are

      - `:cosine`, cosine space
      - `:ip`, inner product space
      - `:l2`, L2 space

  - *dim*: `non_neg_integer()`.

    Number of dimensions for each vector.

  - *max_elements*: `non_neg_integer()`.

    Number of maximum elements.

  ##### Keyword Paramters

  - *m*: `non_neg_integer()`.
  - *ef_construction*: `non_neg_integer()`.
  - *random_seed*: `non_neg_integer()`.
  - *allow_replace_deleted*: `boolean()`.
  """
  @spec new(:cosine | :ip | :l2, non_neg_integer(), non_neg_integer(), [
          {:m, non_neg_integer()},
          {:ef_construction, non_neg_integer()},
          {:random_seed, non_neg_integer()},
          {:allow_replace_deleted, boolean()}
        ]) :: {:ok, %T{}} | {:error, String.t()}
  def new(space, dim, max_elements, opts \\ [])
      when (space == :l2 or space == :ip or space == :cosine) and is_integer(dim) and dim >= 0 and
             is_integer(max_elements) and max_elements >= 0 do
    with {:ok, m} <- Helper.get_keyword(opts, :m, :non_neg_integer, 16),
         {:ok, ef_construction} <-
           Helper.get_keyword(opts, :ef_construction, :non_neg_integer, 200),
         {:ok, random_seed} <- Helper.get_keyword(opts, :random_seed, :non_neg_integer, 100),
         {:ok, allow_replace_deleted} <-
           Helper.get_keyword(opts, :allow_replace_deleted, :boolean, false),
         {:ok, pid} <-
           GenServer.start(
             __MODULE__,
             {space, dim, max_elements, m, ef_construction, random_seed, allow_replace_deleted}
           ) do
      {:ok,
       %T{
         space: space,
         dim: dim,
         pid: pid
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec knn_query(%T{}, Nx.Tensor.t() | binary() | [binary()], [
          {:k, pos_integer()},
          {:num_threads, integer()},
          {:filter, function()}
        ]) :: :ok | {:error, String.t()}
  def knn_query(self, data, opts \\ [])

  def knn_query(self = %T{}, data, opts) when is_binary(data) do
    with {:ok, k} <- Helper.get_keyword(opts, :k, :pos_integer, 1),
         {:ok, num_threads} <- Helper.get_keyword(opts, :num_threads, :integer, -1),
         {:ok, filter} <- Helper.get_keyword(opts, :filter, {:function, 1}, nil, true) do
      if rem(byte_size(data), float_size()) != 0 do
        {:error,
         "vector feature size should be a multiple of #{HNSWLib.Nif.float_size()} (sizeof(float))"}
      else
        features = trunc(byte_size(data) / float_size())

        if features != self.dim do
          {:error, "Wrong dimensionality of the vectors, expect `#{self.dim}`, got `#{features}`"}
        else
          GenServer.call(
            self.pid,
            {:knn_query, data, k, num_threads, filter, 1, features}
          )
        end
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def knn_query(self = %T{}, data, opts) when is_list(data) do
    with {:ok, k} <- Helper.get_keyword(opts, :k, :pos_integer, 1),
         {:ok, num_threads} <- Helper.get_keyword(opts, :num_threads, :integer, -1),
         {:ok, filter} <- Helper.get_keyword(opts, :filter, {:function, 1}, nil, true),
         {:ok, {rows, features}} <- Helper.list_of_binary(data) do
      if features != self.dim do
        {:error, "Wrong dimensionality of the vectors, expect `#{self.dim}`, got `#{features}`"}
      else
        GenServer.call(
          self.pid,
          {:knn_query, IO.iodata_to_binary(data), k, num_threads, filter, rows, features}
        )
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def knn_query(self = %T{}, data = %Nx.Tensor{}, opts) do
    with {:ok, k} <- Helper.get_keyword(opts, :k, :pos_integer, 1),
         {:ok, num_threads} <- Helper.get_keyword(opts, :num_threads, :integer, -1),
         {:ok, filter} <- Helper.get_keyword(opts, :filter, {:function, 1}, nil, true),
         {:ok, f32_data, rows, features} <- verify_data_tensor(self, data) do
      GenServer.call(self.pid, {:knn_query, f32_data, k, num_threads, filter, rows, features})
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_ids_list(%T{}) :: {:ok, [integer()]} | {:error, String.t()}
  def get_ids_list(self = %T{}) do
    GenServer.call(self.pid, :get_ids_list)
  end

  @spec get_ef(%T{}) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def get_ef(self = %T{}) do
    GenServer.call(self.pid, :get_ef)
  end

  @spec set_ef(%T{}, non_neg_integer()) :: :ok | {:error, String.t()}
  def set_ef(self = %T{}, new_ef) when is_integer(new_ef) and new_ef >= 0 do
    GenServer.call(self.pid, {:set_ef, new_ef})
  end

  @spec get_num_threads(%T{}) :: {:ok, integer()} | {:error, String.t()}
  def get_num_threads(self = %T{}) do
    GenServer.call(self.pid, :get_num_threads)
  end

  @spec set_num_threads(%T{}, integer()) :: {:ok, integer()} | {:error, String.t()}
  def set_num_threads(self = %T{}, new_num_threads) do
    GenServer.call(self.pid, {:set_num_threads, new_num_threads})
  end

  @spec save_index(%T{}, Path.t()) :: {:ok, integer()} | {:error, String.t()}
  def save_index(self = %T{}, path) when is_binary(path) do
    GenServer.call(self.pid, {:save_index, path})
  end

  @spec load_index(%T{}, Path.t(), [
          {:max_elements, non_neg_integer()},
          {:allow_replace_deleted, boolean()}
        ]) :: :ok | {:error, String.t()}
  def load_index(self = %T{}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, max_elements} <- Helper.get_keyword(opts, :max_elements, :non_neg_integer, 0),
         {:ok, allow_replace_deleted} <-
           Helper.get_keyword(opts, :allow_replace_deleted, :boolean, false) do
      GenServer.call(self.pid, {:load_index, path, max_elements, allow_replace_deleted})
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec mark_deleted(%T{}, non_neg_integer()) :: :ok | {:error, String.t()}
  def mark_deleted(self = %T{}, label) when is_integer(label) and label >= 0 do
    GenServer.call(self.pid, {:mark_deleted, label})
  end

  @spec unmark_deleted(%T{}, non_neg_integer()) :: :ok | {:error, String.t()}
  def unmark_deleted(self = %T{}, label) when is_integer(label) and label >= 0 do
    GenServer.call(self.pid, {:unmark_deleted, label})
  end

  @spec add_items(%T{}, Nx.Tensor.t() | binary() | [binary()], [
          {:ids, Nx.Tensor.t() | [non_neg_integer()] | nil},
          {:num_threads, integer()},
          {:replace_deleted, false}
        ]) :: :ok | {:error, String.t()}
  def add_items(self, data, opts \\ [])

  def add_items(self = %T{}, data = %Nx.Tensor{}, opts) when is_list(opts) do
    with {:ok, ids} <- normalize_ids(opts[:ids]),
         {:ok, num_threads} <- Helper.get_keyword(opts, :num_threads, :integer, -1),
         {:ok, replace_deleted} <- Helper.get_keyword(opts, :replace_deleted, :boolean, false),
         {:ok, f32_data, rows, features} <- verify_data_tensor(self, data) do
      GenServer.call(
        self.pid,
        {:add_items, f32_data, ids, num_threads, replace_deleted, rows, features}
      )
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_items(%T{}, Nx.Tensor.t() | [integer()], [
          {:return, :tensor | :list | :binary}
        ]) :: {:ok, [[number()]] | Nx.Tensor.t() | [binary()]} | {:error, String.t()}
  def get_items(self = %T{}, ids, opts \\ []) do
    with {:ok, ids} <- normalize_ids(ids),
         {:ok, return} <-
           Helper.get_keyword(opts, :return, {:atom, [:tensor, :list, :binary]}, :tensor) do
      GenServer.call(self.pid, {:get_items, ids, return})
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resize_index(%T{}, non_neg_integer()) :: :ok | {:error, String.t()}
  def resize_index(self = %T{}, new_size) when is_integer(new_size) and new_size >= 0 do
    GenServer.call(self.pid, {:resize_index, new_size})
  end

  @spec get_max_elements(%T{}) :: {:ok, integer()} | {:error, String.t()}
  def get_max_elements(self = %T{}) do
    GenServer.call(self.pid, :get_max_elements)
  end

  @spec get_current_count(%T{}) :: {:ok, integer()} | {:error, String.t()}
  def get_current_count(self = %T{}) do
    GenServer.call(self.pid, :get_current_count)
  end

  @spec get_ef_construction(%T{}) :: {:ok, integer()} | {:error, String.t()}
  def get_ef_construction(self = %T{}) do
    GenServer.call(self.pid, :get_ef_construction)
  end

  @spec get_m(%T{}) :: {:ok, integer()} | {:error, String.t()}
  def get_m(self = %T{}) do
    GenServer.call(self.pid, :get_m)
  end

  defp verify_data_tensor(self = %T{}, data = %Nx.Tensor{}) do
    case data.shape do
      {rows, features} ->
        if features != self.dim do
          {:error, "Wrong dimensionality of the vectors, expect `#{self.dim}`, got `#{features}`"}
        else
          {:ok, Nx.to_binary(Nx.as_type(data, :f32)), rows, features}
        end

      {features} ->
        if features != self.dim do
          {:error, "Wrong dimensionality of the vectors, expect `#{self.dim}`, got `#{features}`"}
        else
          {:ok, Nx.to_binary(Nx.as_type(data, :f32)), 1, features}
        end

      shape ->
        {:error,
         "Input vector data wrong shape. Number of dimensions #{tuple_size(shape)}. Data must be a 1D or 2D array."}
    end
  end

  defp normalize_ids(ids = %Nx.Tensor{}) do
    case ids.shape do
      {_} ->
        {:ok, Nx.to_binary(Nx.as_type(ids, :u64))}

      shape ->
        {:error, "expect ids to be a 1D array, got `#{inspect(shape)}`"}
    end
  end

  defp normalize_ids(ids) when is_list(ids) do
    if Enum.all?(ids, fn x ->
         is_integer(x) and x >= 0
       end) do
      {:ok, ids}
    else
      {:error, "expect `ids` to be a list of non-negative integers"}
    end
  end

  defp normalize_ids(nil) do
    {:ok, nil}
  end

  defp float_size do
    HNSWLib.Nif.float_size()
  end

  # GenServer callbacks

  @impl true
  def init({space, dim, max_elements, m, ef_construction, random_seed, allow_replace_deleted}) do
    case HNSWLib.Nif.new(
           space,
           dim,
           max_elements,
           m,
           ef_construction,
           random_seed,
           allow_replace_deleted
         ) do
      {:ok, ref} ->
        {:ok, ref}

      {:error, reason} ->
        {:stop, {:error, reason}}
    end
  end

  @impl true
  def handle_call({:knn_query, data, k, num_threads, filter, rows, features}, _from, self) do
    case HNSWLib.Nif.knn_query(self, data, k, num_threads, filter, rows, features) do
      any ->
        {:reply, any, self}
    end
  end

  @impl true
  def handle_call(
        {:add_items, f32_data, ids, num_threads, replace_deleted, rows, features},
        _from,
        self
      ) do
    {:reply,
     HNSWLib.Nif.add_items(self, f32_data, ids, num_threads, replace_deleted, rows, features),
     self}
  end

  @impl true
  def handle_call({:get_items, ids, return}, _from, self) do
    with {:ok, data} <- HNSWLib.Nif.get_items(self, ids, return) do
      return_val =
        case return do
          :tensor ->
            Enum.map(data, fn bin ->
              Nx.from_binary(bin, :f32)
            end)

          :binary ->
            data

          :list ->
            data
        end

      {:reply, {:ok, return_val}, self}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, self}
    end
  end

  @impl true
  def handle_call(:get_ids_list, _from, self) do
    {:reply, HNSWLib.Nif.get_ids_list(self), self}
  end

  @impl true
  def handle_call(:get_ef, _from, self) do
    {:reply, HNSWLib.Nif.get_ef(self), self}
  end

  @impl true
  def handle_call({:set_ef, new_ef}, _from, self) do
    {:reply, HNSWLib.Nif.set_ef(self, new_ef), self}
  end

  @impl true
  def handle_call(:get_num_threads, _from, self) do
    {:reply, HNSWLib.Nif.get_num_threads(self), self}
  end

  @impl true
  def handle_call({:set_num_threads, new_num_threads}, _from, self) do
    {:reply, HNSWLib.Nif.set_num_threads(self, new_num_threads), self}
  end

  @impl true
  def handle_call({:save_index, path}, _from, self) do
    {:reply, HNSWLib.Nif.save_index(self, path), self}
  end

  @impl true
  def handle_call({:load_index, path, max_elements, allow_replace_deleted}, _from, self) do
    {:reply, HNSWLib.Nif.load_index(self, path, max_elements, allow_replace_deleted), self}
  end

  @impl true
  def handle_call({:mark_deleted, label}, _from, self) do
    {:reply, HNSWLib.Nif.mark_deleted(self, label), self}
  end

  @impl true
  def handle_call({:unmark_deleted, label}, _from, self) do
    {:reply, HNSWLib.Nif.unmark_deleted(self, label), self}
  end

  @impl true
  def handle_call({:resize_index, new_size}, _from, self) do
    {:reply, HNSWLib.Nif.resize_index(self, new_size), self}
  end

  @impl true
  def handle_call(:get_max_elements, _from, self) do
    {:reply, HNSWLib.Nif.get_max_elements(self), self}
  end

  @impl true
  def handle_call(:get_current_count, _from, self) do
    {:reply, HNSWLib.Nif.get_current_count(self), self}
  end

  @impl true
  def handle_call(:get_ef_construction, _from, self) do
    {:reply, HNSWLib.Nif.get_ef_construction(self), self}
  end

  @impl true
  def handle_call(:get_m, _from, self) do
    {:reply, HNSWLib.Nif.get_m(self), self}
  end

  @impl true
  def handle_info({:knn_query_filter, filter, id}, _self) do
  end
end
