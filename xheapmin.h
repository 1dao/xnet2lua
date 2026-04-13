#ifndef XHEAPMIN_H
#define XHEAPMIN_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

typedef long long long64;

typedef struct xHeapMinNode {
    int heap_index;
    long64 key;
} xHeapMinNode;

typedef int (*fnHeapMinComp)(xHeapMinNode*, xHeapMinNode*);
static inline int xheapmin_compare(xHeapMinNode* a, xHeapMinNode* b) {
    return (int)(a->key - b->key);
}

typedef struct {
    xHeapMinNode** data;
    int capacity;
    int size;
    fnHeapMinComp compare;
} xHeapMin;

// xheapmin api
static inline xHeapMin*       xheapmin_create(int capacity, fnHeapMinComp compare);
static inline void            xheapmin_destroy(xHeapMin* heap);

static inline bool            xheapmin_insert(xHeapMin* heap, xHeapMinNode* node);
static inline xHeapMinNode*   xheapmin_remove(xHeapMin* heap, int index);
static inline xHeapMinNode*   xheapmin_extract(xHeapMin* heap);
static inline xHeapMinNode*   xheapmin_peek(xHeapMin* heap);

static inline int             xheapmin_size(xHeapMin* heap);
static inline bool            xheapmin_check(xHeapMin* heap, xHeapMinNode* node);
static inline void            xheapmin_refresh(xHeapMin* heap, xHeapMinNode* node, long64 new_key);
static inline void            xheapmin_print(xHeapMin* heap);


xHeapMin* xheapmin_create(int capacity, fnHeapMinComp compare) {
    xHeapMin* heap = (xHeapMin*)malloc(sizeof(xHeapMin));
    heap->capacity = capacity;
    heap->size = 0;
    heap->compare = compare;
    heap->data = (xHeapMinNode**)malloc(sizeof(xHeapMinNode*) * capacity);
    return heap;
}

void xheapmin_destroy(xHeapMin* heap) {
    free(heap->data);
    free(heap);
}

static inline int parent(int i) { return (i - 1) / 2; }
static inline int leftChild(int i) { return 2 * i + 1; }
static inline int rightChild(int i) { return 2 * i + 2; }

static inline void swap_nodes(xHeapMin* heap, int i, int j) {
    xHeapMinNode* temp = heap->data[i];
    heap->data[i] = heap->data[j];
    heap->data[j] = temp;

    heap->data[i]->heap_index = i;
    heap->data[j]->heap_index = j;
}

static inline void heapify_up(xHeapMin* heap, int index) {
    if (!heap->compare) {
        while (index > 0) {
            int p = parent(index);
            if (xheapmin_compare(heap->data[p], heap->data[index]) <= 0) {
                break;
            }
            swap_nodes(heap, p, index);
            index = p;
        }
    } else {
        while (index > 0) {
            int p = parent(index);
            if (heap->compare(heap->data[p], heap->data[index]) <= 0) {
                break;
            }
            swap_nodes(heap, p, index);
            index = p;
        }
    }
}

static inline void heapify_down(xHeapMin* heap, int index) {
    int smallest = index;
    if (!heap->compare) {
        while (1) {
            int left = leftChild(index);
            int right = rightChild(index);
            smallest = index;

            if (left < heap->size &&
                xheapmin_compare(heap->data[left], heap->data[smallest]) < 0) {
                smallest = left;
            }

            if (right < heap->size &&
                xheapmin_compare(heap->data[right], heap->data[smallest]) < 0) {
                smallest = right;
            }

            if (smallest == index) break;

            swap_nodes(heap, index, smallest);
            index = smallest;
        }
    } else {
        while (1) {
            int left = leftChild(index);
            int right = rightChild(index);
            smallest = index;

            if (left < heap->size &&
                heap->compare(heap->data[left], heap->data[smallest]) < 0) {
                smallest = left;
            }

            if (right < heap->size &&
                heap->compare(heap->data[right], heap->data[smallest]) < 0) {
                smallest = right;
            }

            if (smallest == index) break;

            swap_nodes(heap, index, smallest);
            index = smallest;
        }
    }
}

bool xheapmin_insert(xHeapMin* heap, xHeapMinNode* node) {
    if (heap->size >= heap->capacity) {
        heap->capacity *= 2;
        heap->data = (xHeapMinNode**)realloc(heap->data,
            sizeof(xHeapMinNode*) * heap->capacity);
    }

    heap->data[heap->size] = node;
    node->heap_index = heap->size;
    heap->size++;

    heapify_up(heap, heap->size - 1);

    return true;
}

xHeapMinNode* xheapmin_remove(xHeapMin* heap, int index) {
    if (index < 0 || index >= heap->size) {
        return NULL;
    }

    xHeapMinNode* removed = heap->data[index];

    heap->data[index] = heap->data[heap->size - 1];
    heap->data[index]->heap_index = index;
    heap->size--;

    if (index < heap->size) {
        heapify_up(heap, index);
        if (heap->data[index]->heap_index == index) {
            heapify_down(heap, index);
        }
    }

    removed->heap_index = -1;
    return removed;
}

xHeapMinNode* xheapmin_extract(xHeapMin* heap) {
    return xheapmin_remove(heap, 0);
}

xHeapMinNode* xheapmin_peek(xHeapMin* heap) {
    return heap->size > 0 ? heap->data[0] : NULL;
}

int xheapmin_size(xHeapMin* heap) {
    return heap->size;
}

bool xheapmin_check(xHeapMin* heap, xHeapMinNode* node) {
    int idx = node->heap_index;
    return idx >= 0 && idx < heap->size && heap->data[idx] == node;
}

void xheapmin_refresh(xHeapMin* heap, xHeapMinNode* node, long64 new_key) {
    if (!xheapmin_check(heap, node)) {
        return;
    }

    long64 old_key = node->key;
    node->key = new_key;

    if (new_key < old_key) {
        heapify_up(heap, node->heap_index);
    } else if (new_key > old_key) {
        heapify_down(heap, node->heap_index);
    }
}

void xheapmin_print(xHeapMin* heap) {
    printf("堆状态: 大小=%d, 容量=%d\n", heap->size, heap->capacity);
    for (int i = 0; i < heap->size; i++) {
        printf("  [%d] key=%lld, heap_index=%d\n",
            i, heap->data[i]->key, heap->data[i]->heap_index);
    }
}

#ifdef __cplusplus
}
#endif
#endif  // XHEAPMIN_H