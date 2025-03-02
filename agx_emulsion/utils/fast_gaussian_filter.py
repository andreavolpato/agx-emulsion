import numpy as np
from numba import njit, prange

@njit(inline='always', cache=True)
def reflect_index(i, n):
    if i < 0:
        return -i
    elif i >= n:
        return 2 * n - i - 2
    else:
        return i

@njit(cache=True)
def gaussian_kernel_1d(sigma, truncate):
    radius = int(truncate * sigma + 0.5)
    size = 2 * radius + 1
    kernel = np.empty(size, dtype=np.float64)
    sum_val = 0.0
    for i in range(size):
        x = i - radius
        val = np.exp(-0.5 * (x / sigma) ** 2)
        kernel[i] = val
        sum_val += val
    for i in range(size):
        kernel[i] /= sum_val
    return kernel, radius

# --- Convolution using Kahan summation ---
@njit(parallel=False, fastmath=True, cache=True)
def convolve_vertical_kahan(image, output, kernel, radius):
    n, m = image.shape
    for i in prange(n):
        for j in range(m):
            sum_val = 0.0
            comp = 0.0
            for k in range(-radius, radius + 1):
                ii = i + k
                if ii < 0:
                    ii = -ii
                elif ii >= n:
                    ii = 2 * n - ii - 2
                term = image[ii, j] * kernel[k + radius]
                y = term - comp
                t = sum_val + y
                comp = (t - sum_val) - y
                sum_val = t
            output[i, j] = sum_val

@njit(parallel=False, fastmath=True, cache=True)
def convolve_horizontal_kahan(image, output, kernel, radius):
    n, m = image.shape
    for i in prange(n):
        for j in range(m):
            sum_val = 0.0
            comp = 0.0
            for k in range(-radius, radius + 1):
                jj = j + k
                if jj < 0:
                    jj = -jj
                elif jj >= m:
                    jj = 2 * m - jj - 2
                term = image[i, jj] * kernel[k + radius]
                y = term - comp
                t = sum_val + y
                comp = (t - sum_val) - y
                sum_val = t
            output[i, j] = sum_val

@njit(fastmath=True, cache=True)
def _gaussian_filter_2d_kahan(image, sigma, truncate):
    kernel, radius = gaussian_kernel_1d(sigma, truncate)
    tmp = np.empty_like(image)
    output = np.empty_like(image)
    convolve_vertical_kahan(image, tmp, kernel, radius)
    convolve_horizontal_kahan(tmp, output, kernel, radius)
    return output

# --- 3D Filtering with scalar sigma ---
@njit(parallel=False, fastmath=True, cache=True)
def fast_gaussian_filter_3d_kahan(image, sigma, truncate):
    n, m, c = image.shape
    output = np.empty_like(image)
    kernel, radius = gaussian_kernel_1d(sigma, truncate)
    for channel in prange(c):
        # Allocate a private temporary array for each channel:
        tmp = np.empty((n, m), dtype=image.dtype)
        img = image[:, :, channel]
        convolve_vertical_kahan(img, tmp, kernel, radius)
        convolve_horizontal_kahan(tmp, output[:, :, channel], kernel, radius)
    return output

# --- 3D Filtering with per-channel sigma ---
@njit(parallel=False, fastmath=True, cache=True)
def fast_gaussian_filter_3d_multi_kahan(image, sigma_arr, truncate):
    n, m, c = image.shape
    output = np.empty_like(image)
    for channel in prange(c):
        s = sigma_arr[channel]
        kernel, radius = gaussian_kernel_1d(s, truncate)
        tmp = np.empty((n, m), dtype=image.dtype)  # allocate tmp inside loop
        img = image[:, :, channel]
        convolve_vertical_kahan(img, tmp, kernel, radius)
        convolve_horizontal_kahan(tmp, output[:, :, channel], kernel, radius)
    return output

def fast_gaussian_filter(image, sigma, truncate=4.0):
    """
    Apply a 2D Gaussian filter (over the first two axes) using Numba with Kahan summation.
    For 3D images, if sigma is a scalar then the same smoothing is applied to all channels;
    if sigma is array-like (one sigma per channel) each channel is filtered with its sigma.
    """
    if image.ndim == 2:
        return _gaussian_filter_2d_kahan(image, sigma, truncate)
    elif image.ndim == 3:
        if np.isscalar(sigma):
            return fast_gaussian_filter_3d_kahan(image, sigma, truncate)
        else:
            sigma_arr = np.asarray(sigma, dtype=np.float64)
            return fast_gaussian_filter_3d_multi_kahan(image, sigma_arr, truncate)
    else:
        raise ValueError("Unsupported image dimension: {}".format(image.ndim))

def warmup_fast_gaussian_filter():
    dummy2d = np.random.rand(64, 64).astype(np.float64)
    dummy3d = np.random.rand(64, 64, 3).astype(np.float64)
    sigma = 1.0
    truncate = 4.0
    fast_gaussian_filter(dummy2d, sigma, truncate)
    fast_gaussian_filter(dummy3d, sigma, truncate)

if __name__ == '__main__':
    import time
    from scipy.ndimage import gaussian_filter
    import matplotlib.pyplot as plt

    print("Warming up...")
    warmup_fast_gaussian_filter()

    img2d = np.random.rand(3000, 2000).astype(np.float64)
    img3d = np.random.rand(3000, 2000, 3).astype(np.float64)
    sigma = 1.0
    truncate = 4.0

    # --- 2D Filtering ---
    filtered_fast_2d = fast_gaussian_filter(img2d, sigma, truncate)
    filtered_scipy_2d = gaussian_filter(img2d, sigma, truncate=truncate, mode='reflect')
    error2d = np.abs(filtered_fast_2d - filtered_scipy_2d).max()
    print("Max error (2D):", error2d)
    plt.figure(figsize=(6, 5))
    plt.imshow(np.abs(filtered_fast_2d - filtered_scipy_2d), cmap='hot')
    plt.colorbar()
    plt.title("Absolute difference: fast_gaussian_filter vs SciPy (2D)")
    plt.show()

    iterations = 3
    t0 = time.time()
    for i in range(iterations):
        fast_gaussian_filter(img2d, sigma, truncate)
    t_fast_2d = (time.time() - t0) / iterations

    t0 = time.time()
    for i in range(iterations):
        gaussian_filter(img2d, sigma, truncate=truncate, mode='reflect')
    t_scipy_2d = (time.time() - t0) / iterations

    print("2D - fast_gaussian_filter time: %.5f s, SciPy time: %.5f s" % (t_fast_2d, t_scipy_2d))

    # --- 3D Filtering with scalar sigma ---
    filtered_fast_3d = fast_gaussian_filter(img3d, sigma, truncate)
    filtered_scipy_3d = gaussian_filter(img3d, sigma, truncate=truncate, mode='reflect')
    error3d = np.abs(filtered_fast_3d - filtered_scipy_3d).max()
    print("Max error (3D, scalar sigma):", error3d)

    t0 = time.time()
    for i in range(iterations):
        fast_gaussian_filter(img3d, sigma, truncate)
    t_fast_3d = (time.time() - t0) / iterations

    t0 = time.time()
    for i in range(iterations):
        gaussian_filter(img3d, sigma, truncate=truncate, mode='reflect')
    t_scipy_3d = (time.time() - t0) / iterations

    print("3D - fast_gaussian_filter time (scalar sigma): %.5f s, SciPy time: %.5f s" % (t_fast_3d, t_scipy_3d))

    # --- 3D Filtering with array sigma ---
    sigma_array = np.array([0.5, 1.0, 1.5])
    filtered_fast_3d_multi = fast_gaussian_filter(img3d, sigma_array, truncate)
    filtered_scipy_3d_multi = np.empty_like(img3d)
    for ch in range(img3d.shape[2]):
        filtered_scipy_3d_multi[:, :, ch] = gaussian_filter(img3d[:, :, ch],
                                                             sigma_array[ch],
                                                             truncate=truncate,
                                                             mode='reflect')
    error3d_multi = np.abs(filtered_fast_3d_multi - filtered_scipy_3d_multi).max()
    print("Max error (3D, multi-sigma):", error3d_multi)

    t0 = time.time()
    for i in range(iterations):
        fast_gaussian_filter(img3d, sigma_array, truncate)
    t_fast_3d_multi = (time.time() - t0) / iterations

    t0 = time.time()
    for i in range(iterations):
        for ch in range(img3d.shape[2]):
            gaussian_filter(img3d[:, :, ch], sigma_array[ch],
                            truncate=truncate, mode='reflect')
    t_scipy_3d_multi = (time.time() - t0) / iterations

    print("3D - fast_gaussian_filter time (multi-sigma): %.5f s, SciPy time: %.5f s" %
          (t_fast_3d_multi, t_scipy_3d_multi))
