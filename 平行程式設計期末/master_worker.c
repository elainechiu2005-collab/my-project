#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <mpi.h>
#include <omp.h>

#define G     6.67430e-11
#define THETA 0.5

typedef struct {
    double x, y, vx, vy, fx, fy, mass;
} Particle;

typedef struct QuadNode {
    double x_min, x_max, y_min, y_max;
    double center_x, center_y, total_mass;
    Particle* p;
    struct QuadNode* children[4];
} QuadNode;

static QuadNode* create_node(double xmin, double xmax, double ymin, double ymax) {
    QuadNode* node = (QuadNode*)malloc(sizeof(QuadNode));
    node->x_min = xmin; node->x_max = xmax;
    node->y_min = ymin; node->y_max = ymax;
    node->center_x = 0; node->center_y = 0;
    node->total_mass = 0;
    node->p = NULL;
    for (int i = 0; i < 4; i++) node->children[i] = NULL;
    return node;
}

static void insert_particle(QuadNode* node, Particle* p) {
    if (!node) return;
    if (node->children[0] != NULL) {
        double mid_x = (node->x_min + node->x_max) / 2.0;
        double mid_y = (node->y_min + node->y_max) / 2.0;
        int idx = (p->x > mid_x ? 1 : 0) + (p->y > mid_y ? 2 : 0);
        insert_particle(node->children[idx], p);
        return;
    }
    if (node->p == NULL) { node->p = p; return; }

    double mid_x = (node->x_min + node->x_max) / 2.0;
    double mid_y = (node->y_min + node->y_max) / 2.0;
    node->children[0] = create_node(node->x_min, mid_x, node->y_min, mid_y);
    node->children[1] = create_node(mid_x, node->x_max, node->y_min, mid_y);
    node->children[2] = create_node(node->x_min, mid_x, mid_y, node->y_max);
    node->children[3] = create_node(mid_x, node->x_max, mid_y, node->y_max);

    Particle* old_p = node->p;
    node->p = NULL;
    if (fabs(old_p->x - p->x) < 1e-9 && fabs(old_p->y - p->y) < 1e-9) {
        p->x += 1e-8; 
        p->y += 1e-8;
    }
    int idx_old = (old_p->x > mid_x ? 1 : 0) + (old_p->y > mid_y ? 2 : 0);
    insert_particle(node->children[idx_old], old_p);
    int idx_new = (p->x > mid_x ? 1 : 0) + (p->y > mid_y ? 2 : 0);
    insert_particle(node->children[idx_new], p);
}

static QuadNode* build_tree(Particle* particles, int N, double space_size) {
    double min_x = particles[0].x, max_x = particles[0].x;
    double min_y = particles[0].y, max_y = particles[0].y;
    for (int i = 1; i < N; i++) {
        if (particles[i].x < min_x) min_x = particles[i].x;
        if (particles[i].x > max_x) max_x = particles[i].x;
        if (particles[i].y < min_y) min_y = particles[i].y;
        if (particles[i].y > max_y) max_y = particles[i].y;
    }
    
    double diff_x = max_x - min_x;
    double diff_y = max_y - min_y;
    double max_diff = (diff_x > diff_y) ? diff_x : diff_y;
    if (max_diff < 1e-5) max_diff = space_size; 
    
    double pad = max_diff * 0.05;
    QuadNode* root = create_node(min_x - pad, min_x + max_diff + pad, 
                                 min_y - pad, min_y + max_diff + pad);
                                 
    for (int i = 0; i < N; i++) {
        insert_particle(root, &particles[i]);
    }
    return root;
}

static void compute_mass_distribution(QuadNode* node) {
    if (!node) return;
    if (node->children[0] == NULL) {
        if (node->p) {
            node->total_mass = node->p->mass;
            node->center_x   = node->p->x;
            node->center_y   = node->p->y;
        }
    } else {
        node->total_mass = 0; node->center_x = 0; node->center_y = 0;
        for (int i = 0; i < 4; i++) {
            if (node->children[i]) {
                compute_mass_distribution(node->children[i]);
                node->total_mass += node->children[i]->total_mass;
                node->center_x   += node->children[i]->center_x * node->children[i]->total_mass;
                node->center_y   += node->children[i]->center_y * node->children[i]->total_mass;
            }
        }
        if (node->total_mass > 0) {
            node->center_x /= node->total_mass;
            node->center_y /= node->total_mass;
        }
    }
}

static void compute_force_bh(Particle* p, QuadNode* node) {
    if (!node || node->total_mass == 0) return;
    double dx = node->center_x - p->x;
    double dy = node->center_y - p->y;
    double dist_sq = dx*dx + dy*dy + 1e-9;
    double dist = sqrt(dist_sq);
    double s = node->x_max - node->x_min;
    if ((s / dist) < THETA || node->children[0] == NULL) {
        if (node->p != p) {
            double force = (G * p->mass * node->total_mass) / dist_sq;
            p->fx += force * (dx / dist);
            p->fy += force * (dy / dist);
        }
    } else {
        for (int i = 0; i < 4; i++) compute_force_bh(p, node->children[i]);
    }
}

static void free_tree(QuadNode* node) {
    if (!node) return;
    for (int i = 0; i < 4; i++) free_tree(node->children[i]);
    free(node);
}

#define TAG_TASK   0   
#define TAG_DONE   1  
#define TAG_DATA   2  

static void simulate_v5(Particle* p, int N, double dt, double space_size,
                         int rank, int size, int chunk_size,
                         double *comm_time, double *compute_time) {
    double tc;

    tc = MPI_Wtime();
    MPI_Bcast(p, N * (int)sizeof(Particle), MPI_BYTE, 0, MPI_COMM_WORLD);
    *comm_time += MPI_Wtime() - tc;

    if (rank == 0) {
        int next_task = 0;
        int active    = 0;
        MPI_Status status;

        for (int w = 1; w < size && next_task < N; w++) {
            tc = MPI_Wtime();
            MPI_Send(&next_task, 1, MPI_INT, w, TAG_TASK, MPI_COMM_WORLD);
            *comm_time += MPI_Wtime() - tc;
            next_task += chunk_size;
            active++;
        }
        for (int w = active + 1; w < size; w++) {
            int term = -1;
            tc = MPI_Wtime();
            MPI_Send(&term, 1, MPI_INT, w, TAG_TASK, MPI_COMM_WORLD);
            *comm_time += MPI_Wtime() - tc;
        }

        while (active > 0) {
            int done_start;
            tc = MPI_Wtime();
            MPI_Recv(&done_start, 1, MPI_INT, MPI_ANY_SOURCE, TAG_DONE,
                     MPI_COMM_WORLD, &status);
            int src = status.MPI_SOURCE;
            int cnt = chunk_size;
            if (done_start + cnt > N) cnt = N - done_start;
            MPI_Recv(&p[done_start], cnt * (int)sizeof(Particle), MPI_BYTE,
                     src, TAG_DATA, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            *comm_time += MPI_Wtime() - tc;

            if (next_task < N) {
                tc = MPI_Wtime();
                MPI_Send(&next_task, 1, MPI_INT, src, TAG_TASK, MPI_COMM_WORLD);
                *comm_time += MPI_Wtime() - tc;
                next_task += chunk_size;
            } else {
                int term = -1;
                tc = MPI_Wtime();
                MPI_Send(&term, 1, MPI_INT, src, TAG_TASK, MPI_COMM_WORLD);
                *comm_time += MPI_Wtime() - tc;
                active--;
            }
        }

        tc = MPI_Wtime();
        MPI_Bcast(p, N * (int)sizeof(Particle), MPI_BYTE, 0, MPI_COMM_WORLD);
        *comm_time += MPI_Wtime() - tc;

    } else {
        double tcomp;

        tcomp = MPI_Wtime();
        QuadNode* root = build_tree(p, N, space_size);
        compute_mass_distribution(root);
        *compute_time += MPI_Wtime() - tcomp;

        int task_start;
        while (1) {
            tc = MPI_Wtime();
            MPI_Recv(&task_start, 1, MPI_INT, 0, TAG_TASK,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            *comm_time += MPI_Wtime() - tc;
            if (task_start == -1) break;

            int task_end = task_start + chunk_size;
            if (task_end > N) task_end = N;

            tcomp = MPI_Wtime();
            #pragma omp parallel for schedule(dynamic, 8)
            for (int i = task_start; i < task_end; i++) {
                p[i].fx = 0.0; p[i].fy = 0.0;
                compute_force_bh(&p[i], root);
                p[i].vx += (p[i].fx / p[i].mass) * dt;
                p[i].vy += (p[i].fy / p[i].mass) * dt;
                p[i].x  += p[i].vx * dt;
                p[i].y  += p[i].vy * dt;
            }
            *compute_time += MPI_Wtime() - tcomp;

            tc = MPI_Wtime();
            MPI_Send(&task_start, 1, MPI_INT, 0, TAG_DONE, MPI_COMM_WORLD);
            MPI_Send(&p[task_start], (task_end - task_start) * (int)sizeof(Particle),
                     MPI_BYTE, 0, TAG_DATA, MPI_COMM_WORLD);
            *comm_time += MPI_Wtime() - tc;
        }

        free_tree(root);
        tc = MPI_Wtime();
        MPI_Bcast(p, N * (int)sizeof(Particle), MPI_BYTE, 0, MPI_COMM_WORLD);
        *comm_time += MPI_Wtime() - tc;
    }
}

int main(int argc, char *argv[]) {
    int provided;
    MPI_Init_thread(&argc, &argv, MPI_THREAD_FUNNELED, &provided);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 2) {
        if (rank == 0)
            fprintf(stderr, "Error: v5 requires at least 2 MPI processes (1 master + 1 worker).\n");
        MPI_Finalize(); return 1;
    }
    if (argc < 2) {
        if (rank == 0)
            printf("Usage: OMP_NUM_THREADS=<T> mpirun -np <P> %s <N> [chunk] [steps]\n", argv[0]);
        MPI_Finalize(); return 1;
    }

    int N          = atoi(argv[1]);
    int chunk_size = (argc >= 3) ? atoi(argv[2]) : 50;
    int steps      = (argc >= 4) ? atoi(argv[3]) : 5;
    double dt         = 0.01;
    double space_size = 1000.0;

    Particle* particles = (Particle*)malloc(N * sizeof(Particle));
    srand(123);
    for (int i = 0; i < N; i++) {
        particles[i].x    = ((double)rand() / RAND_MAX) * space_size;
        particles[i].y    = ((double)rand() / RAND_MAX) * space_size;
        particles[i].vx   = 0.0; particles[i].vy = 0.0;
        particles[i].fx   = 0.0; particles[i].fy = 0.0;
        particles[i].mass = ((double)rand() / RAND_MAX) * 1e24 + 1e20;
    }

    int nthreads = omp_get_max_threads();

    double comm_time = 0.0, compute_time = 0.0;
    MPI_Barrier(MPI_COMM_WORLD);
    double t0 = MPI_Wtime();
    for (int s = 0; s < steps; s++)
        simulate_v5(particles, N, dt, space_size, rank, size, chunk_size,
                    &comm_time, &compute_time);
    MPI_Barrier(MPI_COMM_WORLD);
    double elapsed = MPI_Wtime() - t0;

    double max_worker_compute;
    MPI_Reduce(&compute_time, &max_worker_compute, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        printf("[Master-Worker] N=%-8d Steps=%-4d Procs=%-3d Threads=%-3d Chunk=%-6d Compute=%.4f s  Comm=%.4f s  Total=%.4f s\n",
               N, steps, size, nthreads, chunk_size,
               max_worker_compute, elapsed - max_worker_compute, elapsed);
        double sum_x = 0.0, sum_y = 0.0;
        for (int i = 0; i < N; i++) { sum_x += particles[i].x; sum_y += particles[i].y; }
        printf("  [Verify]   sum_x=%.6e  sum_y=%.6e\n", sum_x, sum_y);
    }

    free(particles);
    MPI_Finalize();
    return 0;
}



