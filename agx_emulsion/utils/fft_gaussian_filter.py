import numpy as np
import pyfftw.interfaces.numpy_fft as fft  # use pyFFTW FFT routines

def fft_gaussian_filter(image, sigma, truncate=7.0, pad=True, parallel=True):
    """
    Apply a Gaussian filter using FFT-based convolution with optional
    mirror padding to reduce edge effects. For 2D images or 3D images with
    multiple channels. If sigma is a scalar, the same standard deviation is used
    for all channels. If sigma is array-like, its length must match the number
    of channels.

    Parameters:
        image : numpy.ndarray
            The input image (2D or 3D).
        sigma : float or array-like of float
            Standard deviation(s) of the Gaussian filter.
        truncate : float, optional
            Truncate the filter at this many standard deviations (default: 4.0).
        pad : bool, optional
            If True, mirror-pad images to reduce FFT wrap-around artifacts.
        parallel : bool, optional
            If True and image is 3D, process channels in parallel.

    Returns:
        numpy.ndarray
            The filtered image.
    """
    if image.ndim == 2:
        sigma_val = sigma if np.isscalar(sigma) else sigma[0]
        return _fft_gaussian_filter_2d(image, sigma_val, truncate, pad)
    elif image.ndim == 3:
        H, W, C = image.shape
        filtered = np.empty_like(image)
        if parallel:
            import concurrent.futures
            def process_channel(c):
                if np.isscalar(sigma):
                    return _fft_gaussian_filter_2d(image[..., c], sigma, truncate, pad)
                else:
                    return _fft_gaussian_filter_2d(image[..., c], sigma[c], truncate, pad)
            with concurrent.futures.ThreadPoolExecutor() as executor:
                results = list(executor.map(process_channel, range(C)))
            for c in range(C):
                filtered[..., c] = results[c]
        else:
            if np.isscalar(sigma):
                for c in range(C):
                    filtered[..., c] = _fft_gaussian_filter_2d(image[..., c], sigma, truncate, pad)
            else:
                sigma = np.asarray(sigma)
                if sigma.size != C:
                    raise ValueError("Length of sigma array must equal the number of channels in the image.")
                for c in range(C):
                    filtered[..., c] = _fft_gaussian_filter_2d(image[..., c], sigma[c], truncate, pad)
        return filtered
    else:
        raise ValueError("Unsupported image dimension: {}".format(image.ndim))

def _fft_gaussian_filter_2d(image, sigma, truncate, pad):
    """
    Apply an FFT-based Gaussian filter for a 2D image with optional mirror padding.
    """
    if pad:
        pad_width = int(truncate * sigma + 0.5)
        # Mirror-pad the image along each side
        image_padded = np.pad(image, pad_width, mode='reflect')
        H_pad, W_pad = image_padded.shape
        kernel_fft = _compute_gaussian_kernel_fft(H_pad, W_pad, sigma)
        filtered_padded = _apply_fft_filter(image_padded, kernel_fft)
        # Crop back to original image size
        filtered = filtered_padded[pad_width:pad_width + image.shape[0],
                                   pad_width:pad_width + image.shape[1]]
        return filtered
    else:
        H, W = image.shape
        kernel_fft = _compute_gaussian_kernel_fft(H, W, sigma)
        return _apply_fft_filter(image, kernel_fft)

def _compute_gaussian_kernel_fft(H, W, sigma):
    """
    Compute the FFT of a Gaussian kernel for a given image size.
    The frequency grid is computed using fft.fftfreq.
    """
    fy = np.fft.fftfreq(H)
    fx = np.fft.fftfreq(W)
    FX, FY = np.meshgrid(fx, fy)
    freq2 = FX**2 + FY**2
    # Fourier representation of a Gaussian:
    kernel_fft = np.exp(-2 * (np.pi**2) * (sigma**2) * freq2)
    return kernel_fft

def _apply_fft_filter(image, kernel_fft):
    """
    Apply FFT-based convolution: FFT of the image, multiply with kernel,
    then inverse FFT.
    Uses pyFFTW for FFT operations.
    """
    image_fft = fft.fft2(image, planner_effort='FFTW_MEASURE')
    filtered_fft = image_fft * kernel_fft
    filtered = fft.ifft2(filtered_fft, planner_effort='FFTW_MEASURE')
    return np.real(filtered)

if __name__=='__main__':
    import time
    from scipy.ndimage import gaussian_filter
    import matplotlib.pyplot as plt

    # Create test images
    image2d = np.random.rand(2000, 2000).astype(np.float64)
    image3d = np.random.rand(2000, 2000, 3).astype(np.float64)

    # Define sigma values: use scalar and per-channel array
    sigma_scalar = 50.0
    sigma_array = np.array([50.0, 50.0, 50.0])

    # --- 2D Filtering ---
    filtered_fft_2d = fft_gaussian_filter(image2d, sigma_scalar, truncate=7.0, pad=True)
    filtered_scipy_2d = gaussian_filter(image2d, sigma_scalar, mode='reflect')
    error_2d = np.abs(filtered_fft_2d - filtered_scipy_2d).max()
    print("2D Max Error:", error_2d)

    # --- 3D Filtering with scalar sigma (sequential) ---
    filtered_fft_3d_scalar = fft_gaussian_filter(image3d, sigma_scalar, truncate=7.0, pad=True)
    filtered_scipy_3d_scalar = gaussian_filter(image3d, sigma_scalar, mode='reflect')
    error_3d_scalar = np.abs(filtered_fft_3d_scalar - filtered_scipy_3d_scalar).max()
    print("3D (scalar sigma) Max Error:", error_3d_scalar)

    # --- 3D Filtering with per-channel sigma (parallel) ---
    filtered_fft_3d_array = fft_gaussian_filter(image3d, sigma_array, truncate=7.0, pad=True, parallel=True)
    # For SciPy we apply the filter per-channel manually
    filtered_scipy_3d_array = np.empty_like(image3d)
    for c in range(image3d.shape[2]):
        filtered_scipy_3d_array[..., c] = gaussian_filter(image3d[..., c], sigma_array[c], mode='reflect')
    error_3d_array = np.abs(filtered_fft_3d_array - filtered_scipy_3d_array).max()
    print("3D (per-channel sigma) Max Error:", error_3d_array)

    # --- Performance Tests ---
    iterations = 3

    # 2D performance
    t0 = time.time()
    for _ in range(iterations):
        fft_gaussian_filter(image2d, sigma_scalar, truncate=4.0, pad=True)
    time_fft_2d = (time.time() - t0) / iterations

    t0 = time.time()
    for _ in range(iterations):
        gaussian_filter(image2d, sigma_scalar, mode='reflect')
    time_scipy_2d = (time.time() - t0) / iterations

    print("2D - FFT-based filter (pyFFTW): %.5f s, SciPy: %.5f s" % (time_fft_2d, time_scipy_2d))

    # 3D filtering with scalar sigma performance (sequential)
    t0 = time.time()
    for _ in range(iterations):
        fft_gaussian_filter(image3d, sigma_array, truncate=4.0, pad=True)
    time_fft_3d_scalar = (time.time() - t0) / iterations

    t0 = time.time()
    for _ in range(iterations):
        for c in range(image3d.shape[2]):
            filtered_scipy_3d_array[..., c] = gaussian_filter(image3d[..., c], sigma_array[c], mode='reflect')
    time_scipy_3d_scalar = (time.time() - t0) / iterations

    print("3D (scalar sigma) - FFT-based filter (pyFFTW): %.5f s, SciPy: %.5f s" % (time_fft_3d_scalar, time_scipy_3d_scalar))

    # (Optional) Visualize difference for 2D filtering
    plt.figure(figsize=(6, 5))
    plt.imshow(np.abs(filtered_fft_2d - filtered_scipy_2d), cmap='hot')
    plt.title("Absolute Difference: FFT-based (pyFFTW) vs SciPy (2D)")
    plt.colorbar()
    plt.show()