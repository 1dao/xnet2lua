#include "xtimer.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 时间轮配置（Linux内核标准参数）
#define TVN_BITS 6
#define TVR_BITS 8
#define TVN_SIZE (1 << TVN_BITS)  // 64
#define TVR_SIZE (1 << TVR_BITS)  // 256
#define TVN_MASK (TVN_SIZE - 1)
#define TVR_MASK (TVR_SIZE - 1)

// 时间轮最大容量：2^32 - 1 毫秒 ≈ 49.7天
#define XTIMER_MAX_INTERVAL 0xFFFFFFFFULL

// 定时器节点状态
#define TIMER_FREE 0
#define TIMER_PENDING 1
#define TIMER_RUNNING 2

// 毒化标记：用于检测已释放的节点
#define TIMER_POISON_ID 0xDEADBEEF

// 定时器节点结构（兼容原有字段）
typedef struct xTimerNode {
    struct xTimerNode* next;
    struct xTimerNode* prev;
    uint64_t expire;         // 绝对超时时间(ms)
    int id;
    fnOnTime callback;
    void* user_data;
    int repeat_num;          /* remaining count; INT_MAX means practically infinite */
    int repeat_interval;     /* milliseconds */
    unsigned char cancelled;
    unsigned char firing;
    unsigned char in_free_list;
    struct xTimerNode* free_next;
    uint32_t slot;           // 所在槽位
    uint8_t level;           // 所在时间轮级别(0-4)
    uint8_t status;          // 节点状态
} xTimerNode;

// 多级时间轮管理器
typedef struct xTimerWheel {
    uint64_t current_jiffies;  // 当前时间戳(ms)
    xTimerNode tv1[TVR_SIZE];  // 一级轮(0-255ms)
    xTimerNode tv2[TVN_SIZE];  // 二级轮(256ms-16383ms)
    xTimerNode tv3[TVN_SIZE];  // 三级轮(16384ms-1048575ms)
    xTimerNode tv4[TVN_SIZE];  // 四级轮(1048576ms-67108863ms)
    xTimerNode tv5[TVN_SIZE];  // 五级轮(67108864ms-4294967295ms)
} xTimerWheel;

// 定时器池结构（完全兼容原有xTimerSet）
typedef struct xTimerSet {
    xTimerWheel wheel;         // 多级时间轮
    int next_timer_id;
    uint64_t current_time;
    xTimerNode* free_list;
    int free_count;
    int free_limit;
    int active_count;          // 精确统计活跃定时器数量
} xTimerSet;

#define XTIMER_MIN_CAP        16
#define XTIMER_DEFAULT_CAP    100
#define XTIMER_FREELIST_MUL   2
#define XTIMER_PREALLOC_COUNT 10000  // 预分配1万个空闲节点

// 线程本地定时器池指针 - 完全复用原有设计
#ifdef _MSC_VER
static __declspec(thread) xTimerSet* _cur = NULL;
#else
static __thread xTimerSet* _cur = NULL;
#endif

/* ------------------------------------------------------------------------- */
/* 时间轮内部工具函数 */
static inline void xtimer_init_list(xTimerNode* head) {
    head->next = head;
    head->prev = head;
}

static inline void xtimer_add_head(xTimerNode* head, xTimerNode* node) {
    node->next = head->next;
    node->prev = head;
    head->next->prev = node;
    head->next = node;
}

static inline void xtimer_remove(xTimerNode* node) {
    node->prev->next = node->next;
    node->next->prev = node->prev;
    node->next = node->prev = NULL;
}

static inline bool xtimer_list_empty(xTimerNode* head) {
    return head->next == head;
}

// 获取指定级别的时间轮数组
static xTimerNode* xtimer_get_wheel(xTimerSet* tm, uint8_t level) {
    switch (level) {
        case 0: return tm->wheel.tv1;
        case 1: return tm->wheel.tv2;
        case 2: return tm->wheel.tv3;
        case 3: return tm->wheel.tv4;
        case 4: return tm->wheel.tv5;
        default: return NULL;
    }
}

// 处理过去时间的定时器
static void xtimer_calc_slot(xTimerSet* tm, uint64_t expire, uint32_t* slot, uint8_t* level) {
    uint64_t delta;
    
    // 处理已经过期的定时器，立即触发
    if (expire <= tm->wheel.current_jiffies) {
        delta = 0;
    } else {
        delta = expire - tm->wheel.current_jiffies;
    }
    
    if (delta < TVR_SIZE) {
        *level = 0;
        *slot = (tm->wheel.current_jiffies + delta) & TVR_MASK;
    } else if (delta < (1 << (TVR_BITS + TVN_BITS))) {
        *level = 1;
        *slot = ((tm->wheel.current_jiffies + delta) >> TVR_BITS) & TVN_MASK;
    } else if (delta < (1 << (TVR_BITS + 2*TVN_BITS))) {
        *level = 2;
        *slot = ((tm->wheel.current_jiffies + delta) >> (TVR_BITS + TVN_BITS)) & TVN_MASK;
    } else if (delta < (1 << (TVR_BITS + 3*TVN_BITS))) {
        *level = 3;
        *slot = ((tm->wheel.current_jiffies + delta) >> (TVR_BITS + 2*TVN_BITS)) & TVN_MASK;
    } else {
        *level = 4;
        *slot = ((tm->wheel.current_jiffies + delta) >> (TVR_BITS + 3*TVN_BITS)) & TVN_MASK;
    }
}

// 插入定时器到对应槽位
static void xtimer_insert(xTimerSet* tm, xTimerNode* node) {
    uint32_t slot;
    uint8_t level;
    
    xtimer_calc_slot(tm, node->expire, &slot, &level);
    
    xTimerNode* wheel = xtimer_get_wheel(tm, level);
    xtimer_add_head(&wheel[slot], node);
    
    node->slot = slot;
    node->level = level;
    node->status = TIMER_PENDING;
    tm->active_count++;  // 精确统计活跃定时器
}

// 安全的链表迁移法
static void xtimer_cascade(xTimerSet* tm, uint8_t level, uint32_t slot) {
    xTimerNode* wheel = xtimer_get_wheel(tm, level);
    xTimerNode* head = &wheel[slot];
    
    if (xtimer_list_empty(head)) {
        return;
    }
    
    // 创建临时链表并转移所有节点
    xTimerNode temp_list;
    xtimer_init_list(&temp_list);
    
    temp_list.next = head->next;
    temp_list.prev = head->prev;
    head->next->prev = &temp_list;
    head->prev->next = &temp_list;
    
    // 清空原链表
    xtimer_init_list(head);
    
    // 遍历临时链表重新插入
    xTimerNode* node = temp_list.next;
    while (node != &temp_list) {
        xTimerNode* next = node->next;
        xtimer_remove(node);
        tm->active_count--;
        xtimer_insert(tm, node);
        node = next;
    }
}

/* ------------------------------------------------------------------------- */
/* node allocation / freelist - 增加指针毒化 */
static void xtimer_prealloc_nodes(xTimerSet* tm, int count) {
    for (int i = 0; i < count; i++) {
        xTimerNode* node = (xTimerNode*)malloc(sizeof(xTimerNode));
        if (!node) break;
        
        node->in_free_list = 1;
        node->id = TIMER_POISON_ID;  // 预分配节点也标记为毒化
        node->free_next = tm->free_list;
        tm->free_list = node;
        tm->free_count++;
    }
}

static xTimerNode* xtimer_node_alloc(xTimerSet* tm) {
    xTimerNode* timer = NULL;
    if (tm && tm->free_list) {
        timer = tm->free_list;
        tm->free_list = timer->free_next;
        tm->free_count--;
        timer->free_next = NULL;
        timer->in_free_list = 0;
        return timer;
    }
    timer = (xTimerNode*)malloc(sizeof(xTimerNode));
    return timer;
}

// 优化一：指针毒化，彻底防止重复释放
static void xtimer_node_release(xTimerSet* tm, xTimerNode* timer) {
    if (!timer) return;
    if (timer->in_free_list) {
        return;
    }
    if (!tm || tm->free_count >= tm->free_limit) {
        free(timer);
        return;
    }
    
    // 毒化所有关键字段，防止野指针访问
    timer->expire = 0;
    timer->id = TIMER_POISON_ID;
    timer->callback = NULL;
    timer->user_data = NULL;
    timer->repeat_num = 0;
    timer->repeat_interval = 0;
    timer->cancelled = 1;
    timer->firing = 0;
    timer->in_free_list = 1;
    timer->slot = 0;
    timer->level = 0;
    timer->status = TIMER_FREE;
    timer->free_next = tm->free_list;
    
    tm->free_list = timer;
    tm->free_count++;
}

static void xtimer_freelist_destroy(xTimerSet* tm) {
    if (!tm) return;
    xTimerNode* p = tm->free_list;
    tm->free_list = NULL;
    tm->free_count = 0;
    while (p) {
        xTimerNode* next = p->free_next;
        p->free_next = NULL;
        p->in_free_list = 0;
        free(p);
        p = next;
    }
}

static xTimerNode* xtimer_node_new(xTimerSet* tm,
                                   int id,
                                   uint64_t timeout,
                                   int interval_ms,
                                   fnOnTime callback,
                                   void* ud,
                                   int repeat_num) {
    xTimerNode* timer = xtimer_node_alloc(tm);
    if (!timer) return NULL;
    timer->expire = timeout;
    timer->id = id;
    timer->callback = callback;
    timer->user_data = ud;
    timer->repeat_num = repeat_num;
    timer->repeat_interval = interval_ms;
    timer->cancelled = 0;
    timer->firing = 0;
    timer->in_free_list = 0;
    timer->free_next = NULL;
    timer->slot = 0;
    timer->level = 0;
    timer->status = TIMER_FREE;
    return timer;
}

/* ------------------------------------------------------------------------- */
/* pool - 对象池配置冲突修复 */
xTimerSet* xtimer_pool_create(int capacity) {
    capacity = (capacity < XTIMER_MIN_CAP) ? XTIMER_MIN_CAP : capacity;
    xTimerSet* tm = (xTimerSet*)malloc(sizeof(xTimerSet));
    if (!tm) return NULL;
    
    memset(&tm->wheel, 0, sizeof(xTimerWheel));
    
    // 初始化所有时间轮槽位
    for (int i = 0; i < TVR_SIZE; i++) {
        xtimer_init_list(&tm->wheel.tv1[i]);
    }
    for (int i = 0; i < TVN_SIZE; i++) {
        xtimer_init_list(&tm->wheel.tv2[i]);
        xtimer_init_list(&tm->wheel.tv3[i]);
        xtimer_init_list(&tm->wheel.tv4[i]);
        xtimer_init_list(&tm->wheel.tv5[i]);
    }
    
    tm->next_timer_id = 1;
    tm->current_time = time_clock_ms();
    tm->wheel.current_jiffies = tm->current_time;
    tm->free_list = NULL;
    tm->free_count = 0;
    tm->free_limit = capacity * XTIMER_FREELIST_MUL;
    
    // 确保free_limit至少等于预分配数量
    if (tm->free_limit < XTIMER_PREALLOC_COUNT) {
        tm->free_limit = XTIMER_PREALLOC_COUNT;
    }
    
    tm->active_count = 0;
    
    // 预分配空闲节点
    xtimer_prealloc_nodes(tm, XTIMER_PREALLOC_COUNT);
    
    return tm;
}

void xtimer_pool_destroy(xTimerSet* tm) {
    if (!tm) return;
    
    // 释放所有活跃定时器节点
    for (int i = 0; i < TVR_SIZE; i++) {
        xTimerNode* head = &tm->wheel.tv1[i];
        xTimerNode* node = head->next;
        while (node != head) {
            xTimerNode* next = node->next;
            free(node);
            node = next;
        }
    }
    
    // 释放高级时间轮节点
    for (int level = 1; level < 5; level++) {
        xTimerNode* wheel = xtimer_get_wheel(tm, level);
        for (int i = 0; i < TVN_SIZE; i++) {
            xTimerNode* head = &wheel[i];
            xTimerNode* node = head->next;
            while (node != head) {
                xTimerNode* next = node->next;
                free(node);
                node = next;
            }
        }
    }
    
    xtimer_freelist_destroy(tm);
    free(tm);
}

/* ------------------------------------------------------------------------- */
/* create / destroy - 增加最大间隔限制和毒化检查 */
xTimerNode* xtimer_create(xTimerSet* tm,
                          int interval_ms,
                          fnOnTime callback,
                          void* ud,
                          int repeat_num) {
    if (!tm) return NULL;
    if (interval_ms < 0) {
        interval_ms = 0;
    }
    
    // 优化三：硬边界拦截，防止超长定时器导致的整数截断
    if ((uint64_t)interval_ms > XTIMER_MAX_INTERVAL) {
        fprintf(stderr, "[ERROR] xtimer_create: interval %dms exceeds maximum capacity (49.7 days)\n",
                interval_ms);
        return NULL;
    }
    
    if (repeat_num == -1) {
        repeat_num = INT_MAX;
    } else if (repeat_num < 1) {
        repeat_num = 1;
    }
    
    uint64_t timeout = tm->current_time + (uint64_t)interval_ms;
    xTimerNode* timer = xtimer_node_new(tm,
                                        tm->next_timer_id++,
                                        timeout,
                                        interval_ms,
                                        callback,
                                        ud,
                                        repeat_num);
    if (!timer) return NULL;
    
    xtimer_insert(tm, timer);
    return timer;
}

// 优化一：增加毒化检查，彻底防止重复释放
void xtimer_destroy(xTimerSet* tm, xTimerNode* timer) {
    // 三重防御：空指针、已释放、已取消、毒化标记
    if (!timer || timer->in_free_list || timer->cancelled || timer->id == TIMER_POISON_ID) {
        return;
    }
    
    timer->cancelled = 1;
    timer->callback = NULL;
    timer->user_data = NULL;
    
    // 只有在时间轮槽位中静止的定时器，才允许立刻移除并回收。
    // 如果是TIMER_RUNNING(已经在temp_list中被锁定)，则只标记cancelled，由poll循环自己回收。
    if (timer->status == TIMER_PENDING) {
        xtimer_remove(timer);
        timer->status = TIMER_FREE;
        tm->active_count--;
        xtimer_node_release(tm, timer);
    }
}

/* ------------------------------------------------------------------------- */
/* poll - 优化下一个超时时间计算 */
int xtimer_poll(xTimerSet* tm) {
    if (!tm) return 0;
    
    tm->current_time = time_clock_ms();
    int next_timeout = TVR_SIZE - 1;
    
    // 处理时间回退（系统时间调整）
    if (tm->current_time < tm->wheel.current_jiffies) {
        fprintf(stderr, "[WARN]: Time went backwards: %llu -> %llu\n",
                (unsigned long long)tm->wheel.current_jiffies,
                (unsigned long long)tm->current_time);
        tm->wheel.current_jiffies = tm->current_time;
        return next_timeout;
    }
    
    // 推进时间轮
    while (tm->wheel.current_jiffies < tm->current_time) {
        uint64_t jiffies = tm->wheel.current_jiffies;
        uint32_t slot = jiffies & TVR_MASK;
        
        // 使用独立的索引变量，避免覆盖
        if (slot == 0) {
            uint32_t idx1 = (jiffies >> TVR_BITS) & TVN_MASK;
            if (idx1 == 0) {
                uint32_t idx2 = (jiffies >> (TVR_BITS + TVN_BITS)) & TVN_MASK;
                if (idx2 == 0) {
                    uint32_t idx3 = (jiffies >> (TVR_BITS + 2*TVN_BITS)) & TVN_MASK;
                    if (idx3 == 0) {
                        uint32_t idx4 = (jiffies >> (TVR_BITS + 3*TVN_BITS)) & TVN_MASK;
                        xtimer_cascade(tm, 4, idx4);
                    }
                    xtimer_cascade(tm, 3, idx3);
                }
                xtimer_cascade(tm, 2, idx2);
            }
            xtimer_cascade(tm, 1, idx1);
        }
        
        // 安全的链表迁移法
        xTimerNode* head = &tm->wheel.tv1[slot];
        if (xtimer_list_empty(head)) {
            tm->wheel.current_jiffies++;
            continue;
        }
        
        // 创建临时链表并转移所有节点
        xTimerNode temp_list;
        xtimer_init_list(&temp_list);
        
        temp_list.next = head->next;
        temp_list.prev = head->prev;
        head->next->prev = &temp_list;
        head->prev->next = &temp_list;
        
        // 清空原链表
        xtimer_init_list(head);

        // 预先将本批次所有节点锁定为RUNNING态
        // 防止当前批次回调中执行xtimer_del时破坏链表结构
        xTimerNode* p = temp_list.next;
        while (p != &temp_list) {
            p->status = TIMER_RUNNING;
            p = p->next;
        }
        
        // 遍历临时链表执行回调
        xTimerNode* node = temp_list.next;
        while (node != &temp_list) {
            xTimerNode* next = node->next;
            xtimer_remove(node);
            tm->active_count--;
            
            node->firing = 1;
            
            if (!node->cancelled && node->callback) {
                node->callback(node->user_data);
            }
            
            node->firing = 0;
            
            if (node->cancelled) {
                xtimer_node_release(tm, node);
            } else if (node->repeat_num > 0 && node->repeat_interval >= 0) {
                --node->repeat_num;
                if (node->repeat_num > 0) {
                    node->expire += (uint64_t)node->repeat_interval;
                    xtimer_insert(tm, node);
                } else {
                    xtimer_node_release(tm, node);
                }
            } else {
                xtimer_node_release(tm, node);
            }
            
            node = next;
        }
        
        tm->wheel.current_jiffies++;
    }
    
    // 优化二：连续内存访问替代位运算寻址
    // 减少CPU指令周期，提升缓存命中率
    uint32_t current_slot = tm->wheel.current_jiffies & TVR_MASK;
    for (uint32_t i = 0; i < TVR_SIZE; i++) {
        uint32_t check_slot = current_slot + i;
        if (check_slot >= TVR_SIZE) {
            check_slot -= TVR_SIZE;
        }
        if (!xtimer_list_empty(&tm->wheel.tv1[check_slot])) {
            next_timeout = i;
            break;
        }
    }
    
    return next_timeout;
}

/* ------------------------------------------------------------------------- */
/* debug */
void xtimer_print(xTimerSet* tm) {
    if (!tm) return;
    printf("\n=== timer manager status (time wheel) ===\n");
    printf("current_time: %llu\n", (unsigned long long)tm->current_time);
    printf("active timers: %d\n", tm->active_count);
    printf("freelist: %d / %d\n", tm->free_count, tm->free_limit);
    
    // 查找下一个定时器
    int next_ms = -1;
    xTimerNode* next_timer = NULL;
    uint32_t current_slot = tm->wheel.current_jiffies & TVR_MASK;
    for (uint32_t i = 0; i < TVR_SIZE; i++) {
        uint32_t check_slot = current_slot + i;
        if (check_slot >= TVR_SIZE) {
            check_slot -= TVR_SIZE;
        }
        if (!xtimer_list_empty(&tm->wheel.tv1[check_slot])) {
            next_ms = i;
            next_timer = tm->wheel.tv1[check_slot].next;
            break;
        }
    }
    
    if (next_timer) {
        printf("next timer: ID=%d, %dms later\n", next_timer->id, next_ms);
    }
}

/* ------------------------------------------------------------------------- */
/* thread-local default timer set - 完全复用原有代码 */
void xtimer_init(int cap) {
    if (!_cur) {
        _cur = xtimer_pool_create(cap);
    }
}

void xtimer_uninit() {
    if (_cur) {
        xtimer_pool_destroy(_cur);
        _cur = NULL;
    }
}

int xtimer_inited() {
    return _cur != NULL;
}

int xtimer_count() {
    return _cur ? _cur->active_count : 0;
}

int xtimer_update() {
    if (_cur) {
        return xtimer_poll(_cur);
    }
    return 0;
}

int xtimer_last() {
    if (_cur) {
        uint32_t current_slot = _cur->wheel.current_jiffies & TVR_MASK;
        for (uint32_t i = 0; i < TVR_SIZE; i++) {
            uint32_t check_slot = current_slot + i;
            if (check_slot >= TVR_SIZE) {
                check_slot -= TVR_SIZE;
            }
            if (!xtimer_list_empty(&_cur->wheel.tv1[check_slot])) {
                return i;
            }
        }
    }
    return -1;
}

void xtimer_show() {
    xtimer_print(_cur);
}

xtimerHandler xtimer_add(int interval_ms,
                         fnOnTime callback,
                         void* ud,
                         int repeat_num) {
    if (!_cur) {
        _cur = xtimer_pool_create(XTIMER_DEFAULT_CAP);
        if (!_cur) return NULL;
    }
    return (xtimerHandler)xtimer_create(_cur,
                                        interval_ms,
                                        callback,
                                        ud,
                                        repeat_num);
}

void xtimer_del(xtimerHandler handler) {
    if (!handler) return;
    if (!_cur) return;
    xtimer_destroy(_cur, (xTimerNode*)handler);
}