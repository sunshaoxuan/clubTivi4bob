import cv2
import numpy as np

def popup_bounds(image, scale):
    mask = (abs(image.astype(np.int16) - 31) <= 1).astype(np.uint8)
    height = round(400 * scale)
    best = None
    integral = cv2.integral(mask)
    for top in range(round(29 * scale), round(86 * scale)):
        bottom = top + height
        if bottom + 5 >= mask.shape[0]:
            break
        vertical = integral[bottom] - integral[top]
        foot = (integral[bottom+5] - integral[bottom]) / 5
        head = (integral[top] - integral[top-4]) / 4
        inner_head = (integral[top+7] - integral[top+3]) / 4
        inner_foot = (integral[bottom-2] - integral[bottom-6]) / 4
        for size in (112, 168, 224, 280):
            width = round(size * scale)
            left = np.arange(5, mask.shape[1] - width - 5)
            right = left + width
            if not left.size:
                continue
            occupancy = (vertical[right] - vertical[left]) / (height * width)
            left_edges = (vertical[left] - vertical[left - 4]) / (4 * height)
            right_edges = (vertical[right + 4] - vertical[right]) / (4 * height)
            edges = (left_edges + right_edges) / 2
            feet = (foot[right - 2] - foot[left + 2]) / (width - 4)
            heads = (head[right - 2] - head[left + 2]) / (width - 4)
            inner_top = (inner_head[right - 5] - inner_head[left + 5]) / (width - 10)
            inner_bottom = (inner_foot[right - 5] - inner_foot[left + 5]) / (width - 10)
            correct_edges = ((inner_top > .75) & (inner_bottom > .75) &
                             (heads < .80) & (feet < .55) &
                             (left_edges < .65) & (right_edges < .65))
            score = np.where((occupancy >= .6) & correct_edges,
                             occupancy - .22 * edges - .19 * feet - .19 * heads, 0)
            index = score.argmax()
            if best is None or score[index] > best[0]:
                best = (score[index], int(left[index]), top, width, height)
    return best[1:] if best is not None and best[0] >= .55 else None

