import time
import functools
import matplotlib.pyplot as plt

def timeit(label):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):
            start = time.perf_counter()
            result = func(self, *args, **kwargs)
            elapsed = time.perf_counter() - start
            self.timings[label] = elapsed
            return result
        return wrapper
    return decorator

def plot_timings(timings):
    labels = list(timings.keys())
    values = [timings[label] for label in labels]
    x_positions = list(range(len(labels)))
    
    fig, ax = plt.subplots(figsize=(8, 4))
    bar_width = 0.8
    ax.bar(x_positions, values, color='skyblue', align='edge', width=bar_width)
    ax.set_xlabel("Function")
    ax.set_ylabel("Time (s)")
    ax.set_title("Execution Time per Function")
    # Adjust tick positions to be at the center of each bar:
    ax.set_xticks([x + bar_width/2 for x in x_positions])
    ax.set_xticklabels(labels, rotation=45, ha='right')
    plt.tight_layout()
    plt.show()