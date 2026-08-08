// Copyright (c) 2026 Yurii Rashkovskii
// SPDX-License-Identifier: MIT OR Apache-2.0

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#if FLYOLOGY_BENCH_HAVE_BOOST
#include <boost/container/vector.hpp>
#include <boost/lockfree/queue.hpp>
#include <boost/lockfree/spsc_queue.hpp>
#include <boost/unordered/unordered_flat_map.hpp>
#endif

#if FLYOLOGY_BENCH_HAVE_ABSEIL
#include <absl/container/flat_hash_map.h>
#endif

namespace {

constexpr std::size_t working_capacity = 1024;

struct contention_result {
  std::uint64_t retries = 0;
  std::uint64_t checksum = 0;
};

std::uint64_t payload(std::uint64_t iteration) {
  return iteration * UINT64_C(0x9e3779b97f4a7c15) + UINT64_C(0x5a5a);
}

inline void observe(std::uint64_t value) {
  asm volatile("" : : "r,m"(value) : "memory");
}

template <typename Operation>
contention_result run_workers(std::uint64_t iterations, unsigned workers,
                              Operation operation) {
  std::atomic<unsigned> ready{0};
  std::atomic<bool> go{false};
  std::vector<std::thread> threads;
  std::vector<contention_result> results(workers);
  threads.reserve(workers);
  for (unsigned worker = 0; worker < workers; ++worker) {
    threads.emplace_back([&, worker] {
      const auto first = iterations * worker / workers;
      const auto last = iterations * (worker + 1) / workers;
      ready.fetch_add(1, std::memory_order_release);
      while (!go.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      for (auto sequence = first; sequence < last; ++sequence) {
        operation(worker, sequence, results[worker]);
      }
    });
  }
  while (ready.load(std::memory_order_acquire) != workers) {
    std::this_thread::yield();
  }
  go.store(true, std::memory_order_release);
  for (auto& thread : threads) {
    thread.join();
  }
  contention_result total;
  for (const auto& result : results) {
    total.retries += result.retries;
    total.checksum += result.checksum;
  }
  return total;
}

template <typename Vector>
contention_result vector_contention(Vector& values, std::mutex& guard,
                                    std::uint64_t iterations,
                                    unsigned workers) {
  values.assign(workers, 0);
  return run_workers(iterations, workers,
                     [&](unsigned worker, std::uint64_t sequence,
                         contention_result& result) {
                       const auto value = payload(sequence + 1);
                       std::lock_guard<std::mutex> lock(guard);
                       values[worker] = value;
                       result.checksum += value;
                     });
}

template <typename Map>
contention_result map_contention(Map& values, std::mutex& guard,
                                 std::uint64_t iterations,
                                 unsigned workers) {
  values.clear();
  values.reserve(2 * workers);
  return run_workers(iterations, workers,
                     [&](unsigned worker, std::uint64_t sequence,
                         contention_result& result) {
                       const auto value = payload(sequence + 1);
                       std::lock_guard<std::mutex> lock(guard);
                       values.insert_or_assign(worker + 1, value);
                       result.checksum += value;
                     });
}

contention_result string_contention(std::string& value, std::mutex& guard,
                                    std::uint64_t iterations,
                                    unsigned workers) {
  value.clear();
  return run_workers(iterations, workers,
                     [&](unsigned, std::uint64_t,
                         contention_result& result) {
                       std::lock_guard<std::mutex> lock(guard);
                       value.assign("flyology");
                       result.checksum += value.size();
                     });
}

template <typename Push, typename Pop>
contention_result queue_contention(std::uint64_t iterations,
                                   unsigned producers, unsigned consumers,
                                   Push push, Pop pop) {
  const unsigned workers = producers + consumers;
  std::atomic<unsigned> ready{0};
  std::atomic<bool> go{false};
  std::vector<std::thread> threads;
  std::vector<contention_result> results(workers);
  threads.reserve(workers);
  for (unsigned worker = 0; worker < workers; ++worker) {
    threads.emplace_back([&, worker] {
      const bool producer = worker < producers;
      const unsigned lane = producer ? worker : worker - producers;
      const unsigned lanes = producer ? producers : consumers;
      const auto first = iterations * lane / lanes;
      const auto last = iterations * (lane + 1) / lanes;
      ready.fetch_add(1, std::memory_order_release);
      while (!go.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      for (auto sequence = first; sequence < last; ++sequence) {
        if (producer) {
          while (!push(payload(sequence + 1))) {
            ++results[worker].retries;
            std::this_thread::yield();
          }
        } else {
          std::uint64_t value = 0;
          while (!pop(value)) {
            ++results[worker].retries;
            std::this_thread::yield();
          }
          results[worker].checksum += value;
        }
      }
    });
  }
  while (ready.load(std::memory_order_acquire) != workers) {
    std::this_thread::yield();
  }
  go.store(true, std::memory_order_release);
  for (auto& thread : threads) {
    thread.join();
  }
  contention_result total;
  for (const auto& result : results) {
    total.retries += result.retries;
    total.checksum += result.checksum;
  }
  return total;
}

template <typename Vector>
std::uint64_t vector_batch(Vector& values, std::mutex* guard,
                           std::uint64_t iterations) {
  values.clear();
  values.reserve(working_capacity);
  std::size_t count = 0;
  std::uint64_t checksum = 0;
  for (std::uint64_t iteration = 1; iteration <= iterations; ++iteration) {
    if (count == working_capacity) {
      if (guard != nullptr) {
        std::lock_guard<std::mutex> lock(*guard);
        values.clear();
      } else {
        values.clear();
      }
      count = 0;
    }
    const auto value = payload(iteration);
    if (guard != nullptr) {
      {
        std::lock_guard<std::mutex> lock(*guard);
        values.push_back(value);
      }
      {
        std::lock_guard<std::mutex> lock(*guard);
        checksum += values[count];
      }
    } else {
      values.push_back(value);
      checksum += values[count];
    }
    ++count;
    observe(checksum);
  }
  return checksum;
}

template <typename Map>
std::uint64_t map_batch(Map& values, std::mutex* guard,
                        std::uint64_t iterations) {
  values.clear();
  values.reserve(2 * working_capacity);
  std::uint64_t checksum = 0;
  for (std::uint64_t iteration = 1; iteration <= iterations; ++iteration) {
    const auto cycle = (iteration - 1) % working_capacity;
    if (cycle == 0) {
      if (guard != nullptr) {
        std::lock_guard<std::mutex> lock(*guard);
        values.clear();
      } else {
        values.clear();
      }
    }
    const auto key = cycle + 1;
    const auto value = payload(iteration);
    if (guard != nullptr) {
      {
        std::lock_guard<std::mutex> lock(*guard);
        values.insert_or_assign(key, value);
      }
      {
        std::lock_guard<std::mutex> lock(*guard);
        checksum += values.find(key)->second;
      }
    } else {
      values.insert_or_assign(key, value);
      checksum += values.find(key)->second;
    }
    observe(checksum);
  }
  return checksum;
}

std::vector<std::uint64_t> std_vector;
std::vector<std::uint64_t> std_vector_locked;
std::mutex std_vector_mutex;
std::unordered_map<std::uint64_t, std::uint64_t> std_map;
std::unordered_map<std::uint64_t, std::uint64_t> std_map_locked;
std::mutex std_map_mutex;
std::string std_string;
std::string std_string_locked;
std::mutex std_string_mutex;
std::deque<std::uint64_t> std_queue;
std::mutex std_queue_mutex;

#if FLYOLOGY_BENCH_HAVE_BOOST
boost::container::vector<std::uint64_t> boost_vector;
boost::container::vector<std::uint64_t> boost_vector_locked;
std::mutex boost_vector_mutex;
boost::unordered_flat_map<std::uint64_t, std::uint64_t> boost_map;
boost::unordered_flat_map<std::uint64_t, std::uint64_t> boost_map_locked;
std::mutex boost_map_mutex;
boost::lockfree::spsc_queue<
    std::uint64_t, boost::lockfree::capacity<working_capacity>> boost_spsc;
boost::lockfree::queue<
    std::uint64_t, boost::lockfree::capacity<working_capacity>> boost_mpmc;
#endif

#if FLYOLOGY_BENCH_HAVE_ABSEIL
absl::flat_hash_map<std::uint64_t, std::uint64_t> absl_map;
absl::flat_hash_map<std::uint64_t, std::uint64_t> absl_map_locked;
std::mutex absl_map_mutex;
#endif

}  // namespace

extern "C" int flyology_ds_cpp_have_boost() {
#if FLYOLOGY_BENCH_HAVE_BOOST
  return 1;
#else
  return 0;
#endif
}

extern "C" int flyology_ds_cpp_have_abseil() {
#if FLYOLOGY_BENCH_HAVE_ABSEIL
  return 1;
#else
  return 0;
#endif
}

extern "C" const char* flyology_ds_cpp_compiler() {
#if defined(__clang__)
  return "Clang " __clang_version__;
#elif defined(__GNUC__)
  return "GCC " __VERSION__;
#else
  return "unknown C++ compiler";
#endif
}

extern "C" int flyology_ds_cpp_vector_batch(int provider,
                                              std::uint64_t iterations,
                                              std::uint64_t* checksum) {
  if (checksum == nullptr) {
    return 1;
  }
  try {
    switch (provider) {
      case 0:
        *checksum = vector_batch(std_vector, nullptr, iterations);
        return 0;
      case 1:
        *checksum =
            vector_batch(std_vector_locked, &std_vector_mutex, iterations);
        return 0;
#if FLYOLOGY_BENCH_HAVE_BOOST
      case 2:
        *checksum = vector_batch(boost_vector, nullptr, iterations);
        return 0;
      case 3:
        *checksum =
            vector_batch(boost_vector_locked, &boost_vector_mutex, iterations);
        return 0;
#endif
      default:
        return 1;
    }
  } catch (...) {
    return 2;
  }
}

extern "C" int flyology_ds_cpp_map_batch(int provider,
                                           std::uint64_t iterations,
                                           std::uint64_t* checksum) {
  if (checksum == nullptr) {
    return 1;
  }
  try {
    switch (provider) {
      case 0:
        *checksum = map_batch(std_map, nullptr, iterations);
        return 0;
      case 1:
        *checksum = map_batch(std_map_locked, &std_map_mutex, iterations);
        return 0;
#if FLYOLOGY_BENCH_HAVE_BOOST
      case 2:
        *checksum = map_batch(boost_map, nullptr, iterations);
        return 0;
      case 3:
        *checksum = map_batch(boost_map_locked, &boost_map_mutex, iterations);
        return 0;
#endif
#if FLYOLOGY_BENCH_HAVE_ABSEIL
      case 4:
        *checksum = map_batch(absl_map, nullptr, iterations);
        return 0;
      case 5:
        *checksum = map_batch(absl_map_locked, &absl_map_mutex, iterations);
        return 0;
#endif
      default:
        return 1;
    }
  } catch (...) {
    return 2;
  }
}

extern "C" int flyology_ds_cpp_string_batch(int provider,
                                              std::uint64_t iterations,
                                              std::uint64_t* checksum) {
  if (checksum == nullptr) {
    return 1;
  }
  try {
    std::uint64_t local = 0;
    for (std::uint64_t iteration = 0; iteration < iterations; ++iteration) {
      if (provider == 0) {
        std_string.assign("flyology");
        local += std_string.size();
      } else if (provider == 1) {
        {
          std::lock_guard<std::mutex> lock(std_string_mutex);
          std_string_locked.assign("flyology");
        }
        {
          std::lock_guard<std::mutex> lock(std_string_mutex);
          local += std_string_locked.size();
        }
      } else {
        return 1;
      }
      observe(local);
    }
    *checksum = local;
    return 0;
  } catch (...) {
    return 2;
  }
}

extern "C" int flyology_ds_cpp_queue_batch(int provider,
                                             std::uint64_t iterations,
                                             std::uint64_t* checksum) {
  if (checksum == nullptr) {
    return 1;
  }
  try {
    std::uint64_t local = 0;
    for (std::uint64_t iteration = 1; iteration <= iterations; ++iteration) {
      const auto value = payload(iteration);
      std::uint64_t observed = 0;
      if (provider == 0) {
        {
          std::lock_guard<std::mutex> lock(std_queue_mutex);
          std_queue.push_back(value);
        }
        {
          std::lock_guard<std::mutex> lock(std_queue_mutex);
          observed = std_queue.front();
          std_queue.pop_front();
        }
#if FLYOLOGY_BENCH_HAVE_BOOST
      } else if (provider == 1) {
        if (!boost_spsc.push(value) || !boost_spsc.pop(observed)) {
          return 3;
        }
      } else if (provider == 2) {
        if (!boost_mpmc.push(value) || !boost_mpmc.pop(observed)) {
          return 3;
        }
#endif
      } else {
        return 1;
      }
      local += observed;
      observe(local);
    }
    *checksum = local;
    return 0;
  } catch (...) {
    return 2;
  }
}

extern "C" int flyology_ds_cpp_contention_batch(
    int structure, int provider, std::uint64_t iterations, unsigned workers,
    std::uint64_t* retries, std::uint64_t* checksum) {
  if (workers < 2 || retries == nullptr || checksum == nullptr) {
    return 1;
  }
  try {
    contention_result result;
    switch (structure) {
      case 0:
        if (provider == 0) {
          result = vector_contention(std_vector_locked, std_vector_mutex,
                                     iterations, workers);
#if FLYOLOGY_BENCH_HAVE_BOOST
        } else if (provider == 1) {
          result = vector_contention(boost_vector_locked, boost_vector_mutex,
                                     iterations, workers);
#endif
        } else {
          return 1;
        }
        break;
      case 1:
        if (provider == 0) {
          result = map_contention(std_map_locked, std_map_mutex, iterations,
                                  workers);
#if FLYOLOGY_BENCH_HAVE_BOOST
        } else if (provider == 1) {
          result = map_contention(boost_map_locked, boost_map_mutex, iterations,
                                  workers);
#endif
#if FLYOLOGY_BENCH_HAVE_ABSEIL
        } else if (provider == 2) {
          result = map_contention(absl_map_locked, absl_map_mutex, iterations,
                                  workers);
#endif
        } else {
          return 1;
        }
        break;
      case 2:
        if (provider != 0) {
          return 1;
        }
        result = string_contention(std_string_locked, std_string_mutex,
                                   iterations, workers);
        break;
      case 3:
      case 4: {
        if (structure == 3 && workers != 2) {
          return 1;
        }
        if (structure == 4 && workers % 2 != 0) {
          return 1;
        }
        const unsigned producers = structure == 3 ? 1 : workers / 2;
        const unsigned consumers = structure == 3 ? 1 : workers / 2;
        if (provider == 0) {
          {
            std::lock_guard<std::mutex> lock(std_queue_mutex);
            std_queue.clear();
          }
          result = queue_contention(
              iterations, producers, consumers,
              [](std::uint64_t value) {
                std::lock_guard<std::mutex> lock(std_queue_mutex);
                if (std_queue.size() == working_capacity) {
                  return false;
                }
                std_queue.push_back(value);
                return true;
              },
              [](std::uint64_t& value) {
                std::lock_guard<std::mutex> lock(std_queue_mutex);
                if (std_queue.empty()) {
                  return false;
                }
                value = std_queue.front();
                std_queue.pop_front();
                return true;
              });
#if FLYOLOGY_BENCH_HAVE_BOOST
        } else if (provider == 1 && structure == 3) {
          std::uint64_t discarded = 0;
          while (boost_spsc.pop(discarded)) {
          }
          result = queue_contention(
              iterations, 1, 1,
              [](std::uint64_t value) { return boost_spsc.push(value); },
              [](std::uint64_t& value) { return boost_spsc.pop(value); });
        } else if (provider == 1 && structure == 4) {
          std::uint64_t discarded = 0;
          while (boost_mpmc.pop(discarded)) {
          }
          result = queue_contention(
              iterations, producers, consumers,
              [](std::uint64_t value) { return boost_mpmc.push(value); },
              [](std::uint64_t& value) { return boost_mpmc.pop(value); });
#endif
        } else {
          return 1;
        }
        break;
      }
      default:
        return 1;
    }
    *retries = result.retries;
    *checksum = result.checksum;
    return 0;
  } catch (...) {
    return 2;
  }
}
