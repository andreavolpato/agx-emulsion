import numpy as np
from numba import njit, prange
from math import sqrt, exp

@njit(parallel=True, cache=True)
def fast_binomial(N_arr, p_arr):
    """
    Generate a 2D array of binomial random numbers.
    
    For each cell (i,j), with parameters:
      - n = N_arr[i,j]
      - p = p_arr[i,j]
      
    The function automatically chooses:
      - Direct simulation for small n,
      - Normal approximation if variance np(1-p) is high,
      - Inversion method if variance is low.
      
    Parameters
    ----------
    N_arr : 2D numpy array of integers
        Number of trials for each cell.
    p_arr : 2D numpy array of floats
        Success probability for each cell.
    
    Returns
    -------
    result : 2D numpy array of integers
        Binomial random variates.
    """
    n_rows, n_cols = N_arr.shape
    result = np.empty((n_rows, n_cols), dtype=np.int64)
    
    # Threshold for using the direct method.
    n_threshold = 25  
    for i in prange(n_rows):
        for j in range(n_cols):
            n = N_arr[i, j]
            p = p_arr[i, j]
            
            # Handle trivial cases.
            if p <= 0.0:
                result[i, j] = 0
            elif p >= 1.0:
                result[i, j] = n
            else:
                if n < n_threshold:
                    # Direct simulation: loop over n Bernoulli trials.
                    count = 0
                    for k in range(n):
                        if np.random.rand() < p:
                            count += 1
                    result[i, j] = count
                else:
                    # For high n, we decide based on variance.
                    mean = n * p
                    var = n * p * (1 - p)
                    if var > 10:  
                        # Use Normal approximation:
                        # X ≈ N(np, np(1-p))
                        z = np.random.randn()  # standard normal variate
                        approx = mean + sqrt(var) * z
                        # Round and clip to [0, n]
                        approx_int = int(np.round(approx))
                        if approx_int < 0:
                            approx_int = 0
                        elif approx_int > n:
                            approx_int = n
                        result[i, j] = approx_int
                    else:
                        # Use Inversion method:
                        u = np.random.rand()
                        cdf = 0.0
                        # Initial probability P(X=0)
                        prob = (1 - p)**n  
                        k = 0
                        # Increment until the cumulative probability exceeds u.
                        while cdf < u and k <= n:
                            cdf += prob
                            if k < n:
                                # Compute P(X=k+1) recursively:
                                prob = prob * ((n - k) / (k + 1)) * (p / (1 - p))
                            k += 1
                        result[i, j] = k - 1  # k-1 is the generated sample
    return result

@njit(parallel=True, cache=True)
def fast_poisson(lam_arr):
    """
    Generate a 2D array of Poisson random numbers from a 2D array of lambda parameters.
    
    For each cell (i,j) with parameter lambda = lam_arr[i, j]:
      - If lambda <= 0, returns 0.
      - If lambda < threshold (here, 30), uses Knuth's algorithm.
      - Otherwise, uses the normal approximation:
          X ~ Normal(lambda, sqrt(lambda))
        with rounding and clipping to ensure a nonnegative integer.
    
    Parameters
    ----------
    lam_arr : 2D numpy array of floats
        Rate parameters (λ) for the Poisson distributions.
    
    Returns
    -------
    result : 2D numpy array of int64
        Poisson random variates corresponding to each λ.
    """
    n_rows, n_cols = lam_arr.shape
    result = np.empty((n_rows, n_cols), dtype=np.int64)
    # Threshold to switch methods
    lam_threshold = 30.0
    
    for i in prange(n_rows):
        for j in range(n_cols):
            lam = lam_arr[i, j]
            # Handle edge case: non-positive lambda.
            if lam <= 0.0:
                result[i, j] = 0
            elif lam < lam_threshold:
                # Use Knuth's algorithm for Poisson sampling.
                L = exp(-lam)
                p = 1.0
                k = 0
                while p > L:
                    k += 1
                    p *= np.random.rand()
                result[i, j] = k - 1
            else:
                # Use Normal approximation for high lambda.
                # Normal approximation: X ≈ N(lam, lam)
                z = np.random.randn()  # standard normal variate
                sample = lam + sqrt(lam) * z
                # Round to the nearest integer.
                sample_int = int(np.round(sample))
                if sample_int < 0:
                    sample_int = 0
                result[i, j] = sample_int
    return result

@njit(parallel=True, cache=True)
def fast_lognormal(mu_arr, sigma_arr):
    """
    Generate a 2D array of lognormal random variates.
    
    For each cell (i,j) with parameters:
      - mu = mu_arr[i, j]
      - sigma = sigma_arr[i, j]
    
    The lognormal variable is given by:
         X = exp(mu + sigma * Z)
    where Z ~ N(0,1). For very small sigma, where the distribution is
    nearly deterministic, we simply return exp(mu).
    
    Parameters
    ----------
    mu_arr : 2D numpy array of floats
        Array of mu parameters.
    sigma_arr : 2D numpy array of floats
        Array of sigma parameters.
    
    Returns
    -------
    result : 2D numpy array of floats
        Lognormal random variates.
    """
    n_rows, n_cols = mu_arr.shape
    result = np.empty((n_rows, n_cols), dtype=np.float64)
    
    # Define a threshold below which sigma is considered effectively zero.
    sigma_threshold = 1e-6
    
    for i in prange(n_rows):
        for j in range(n_cols):
            mu = mu_arr[i, j]
            sigma = sigma_arr[i, j]
            if sigma < sigma_threshold:
                # For near-zero sigma, the lognormal distribution nearly
                # collapses to a point mass at exp(mu).
                result[i, j] = exp(mu)
            else:
                # Sample from the standard normal and transform.
                z = np.random.randn()
                result[i, j] = exp(mu + sigma * z)
    return result

def fast_stats_warmup():
    # launch once so the function is pre compiled
    dummy_lambda = np.array([[1.0, 2.0], [3.0, 4.0]], dtype=np.float64)
    dummy_N = np.array([[10,20],[30,40]], dtype=np.int64)
    dummy_p = np.array([[0.5,0.5],[0.5,0.5]], dtype=np.float64)
    dummy_mu = np.array([[0.0, 1.0], [0.5, -0.5]], dtype=np.float64)
    dummy_sigma = np.array([[0.1, 0.2], [0.3, 0.4]], dtype=np.float64)
    _ = fast_poisson(dummy_lambda)
    _ = fast_binomial(dummy_N, dummy_p)
    _ = fast_lognormal(dummy_mu, dummy_sigma)
    return

if __name__=='__main__':
    import time

    size = (6000, 4000)  # Large batch for benchmarking
    # size = (10000, 10000)  # Large batch for benchmarking

    pixel_area = (35000/size[0])**2
    particle_area = 0.2
    n = pixel_area/particle_area
    n_max = np.int64(np.ceil(n*1.3))
    n_min = np.int64(n*0.8)
    print('n:',n)

    lam_array = np.random.uniform(n_min, n_max, size)
    n_array = np.random.randint(n_min, n_max, size)  # Random n values
    p_array = np.random.uniform(0, 1, size)  # Random probabilities
    
    start = time.time()
    fast_stats_warmup()
    print("Warm-up time:", (time.time() - start))

    # Benchmark NumPy
    start = time.time()
    poisson_np = np.random.default_rng().poisson(lam_array)
    binomial_np = np.random.default_rng().binomial(poisson_np, p_array)
    _ = np.random.lognormal(lam_array, p_array)    
    print("NumPy Binomial+Poisson Time (1 run x 9):", (time.time() - start)*9)

    # 4 megapixel is the cross-over point for the efficiency of normal numpy and the optimized numba functions

    # Benchmark Optimized
    start = time.time()
    for i in np.arange(9):
        poisson_fast_auto = fast_poisson(lam_array)
        binomial_fast_auto = fast_binomial(poisson_fast_auto, p_array)
    _ = fast_lognormal(lam_array, p_array)
    print("Fast Poisson+Poisson Time (9 runs):", (time.time() - start))
