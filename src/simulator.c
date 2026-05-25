// galcon.c – Galcon game simulator with client–server architecture
// Compile: gcc -O3 -o galcon galcon.c -lm -pthread
// Usage: ./galcon server [port]        – start game server
//        ./galcon client <host> <port> – start bot client (for external bots)
//        ./galcon test <bot1> <bot2> <matches> – internal statistics test

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>

// ----------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------
#define MAX_ITEMS       10000
#define MAX_PLANETS      200
#define MAX_FLEETS      2000
#define MAX_LINE        4096
#define TICK_DURATION    0.1    // seconds per tick (simulated)
#define PRODUCTION_INTERVAL 1.0 // seconds per production tick (2 ticks per sec)
#define SHIP_FACTOR      30.0   // speed factor: distance / SHIP_FACTOR seconds
#define SEND_PERCENT_MIN    5
#define SEND_PERCENT_MAX  100

// ----------------------------------------------------------------------
// Game data structures
// ----------------------------------------------------------------------
typedef enum { OBJ_USER, OBJ_PLANET, OBJ_FLEET } ObjType;

typedef struct {
    int      id;
    ObjType  type;
    double   x, y;
    double   radius;
    double   ships;
    int      owner;          // user id (0 = neutral)
    int      team;
    double   production;     // only for planets
    int      source, target; // only for fleets
    char     name[32];
    int      color;
} Item;

typedef struct {
    Item items[MAX_ITEMS];
    int  item_count;
    int  you;                // bot's user id (for parsing)
    char state[64];
    double time;             // simulation time
    double next_production;
} Galaxy;

// ----------------------------------------------------------------------
// Helper functions
// ----------------------------------------------------------------------
static double distance(double x1, double y1, double x2, double y2) {
    double dx = x1 - x2, dy = y1 - y2;
    return sqrt(dx*dx + dy*dy);
}

static Item* find_item(Galaxy* g, int id) {
    for (int i = 0; i < g->item_count; i++)
        if (g->items[i].id == id)
            return &g->items[i];
    return NULL;
}

static int get_team(Galaxy* g, int owner_id) {
    if (owner_id == 0) return 0;
    Item* u = find_item(g, owner_id);
    return u ? u->team : 0;
}

// ----------------------------------------------------------------------
// Galaxy update – core simulation
// ----------------------------------------------------------------------
static void update_fleets(Galaxy* g, double dt) {
    for (int i = 0; i < g->item_count; i++) {
        Item* f = &g->items[i];
        if (f->type != OBJ_FLEET) continue;
        Item* src = find_item(g, f->source);
        Item* tgt = find_item(g, f->target);
        if (!src || !tgt) {
            // invalid – destroy fleet
            g->items[i--] = g->items[--g->item_count];
            continue;
        }
        double total_dist = distance(src->x, src->y, tgt->x, tgt->y);
        if (total_dist < 1e-6) total_dist = 1e-6;
        double speed = total_dist / SHIP_FACTOR;
        double move = dt * speed;
        // update position
        double dx = tgt->x - src->x;
        double dy = tgt->y - src->y;
        double len = sqrt(dx*dx + dy*dy);
        if (len > 1e-6) {
            dx /= len; dy /= len;
        }
        f->x += dx * move;
        f->y += dy * move;
        // arrival?
        if (distance(f->x, f->y, tgt->x, tgt->y) < 5.0) { // arrived
            // combat: attacker vs defender
            Item* planet = tgt;
            int attacker_team = get_team(g, f->owner);
            int defender_team = get_team(g, planet->owner);
            if (attacker_team == defender_team) {
                // reinforce
                planet->ships += f->ships;
            } else {
                // fight
                if (f->ships > planet->ships) {
                    // capture
                    planet->ships = f->ships - planet->ships;
                    planet->owner = f->owner;
                } else {
                    // defender wins
                    planet->ships -= f->ships;
                }
            }
            // remove fleet
            g->items[i--] = g->items[--g->item_count];
        }
    }
}

static void update_production(Galaxy* g, double now) {
    if (now < g->next_production) return;
    g->next_production = now + PRODUCTION_INTERVAL;
    for (int i = 0; i < g->item_count; i++) {
        Item* p = &g->items[i];
        if (p->type == OBJ_PLANET && p->owner != 0) {
            p->ships += p->production;
            if (p->ships < 0) p->ships = 0;
        }
    }
}

static void run_tick(Galaxy* g, double dt) {
    g->time += dt;
    update_fleets(g, dt);
    update_production(g, g->time);
}

// ----------------------------------------------------------------------
// Protocol parsing (server side – receives commands from bots)
// ----------------------------------------------------------------------
static void execute_command(Galaxy* g, const char* line) {
    char cmd[32];
    int pct, src, tgt;
    if (sscanf(line, "/SEND %d %d %d", &pct, &src, &tgt) == 3) {
        Item* planet = find_item(g, src);
        if (planet && planet->type == OBJ_PLANET && planet->owner == g->you) {
            if (pct < SEND_PERCENT_MIN) pct = SEND_PERCENT_MIN;
            if (pct > SEND_PERCENT_MAX) pct = SEND_PERCENT_MAX;
            double ships_sent = planet->ships * (pct / 100.0);
            if (ships_sent < 1.0) ships_sent = 1.0;
            planet->ships -= ships_sent;
            // create fleet
            Item* fleet = &g->items[g->item_count++];
            fleet->id = rand(); // not critical
            fleet->type = OBJ_FLEET;
            fleet->x = planet->x;
            fleet->y = planet->y;
            fleet->ships = ships_sent;
            fleet->owner = g->you;
            fleet->source = src;
            fleet->target = tgt;
            fleet->radius = 3.0;
        }
    } else if (sscanf(line, "/REDIR %d %d", &src, &tgt) == 2) {
        // redirect all fleets that originated from src
        for (int i = 0; i < g->item_count; i++) {
            Item* f = &g->items[i];
            if (f->type == OBJ_FLEET && f->owner == g->you && f->source == src) {
                f->target = tgt;
                // recalc direction? no, will update on next tick
            }
        }
    } else if (strcmp(line, "/TOCK") == 0) {
        // ignored – used for sync
    }
}

// ----------------------------------------------------------------------
// Bot AI implementations (for internal testing)
// ----------------------------------------------------------------------
typedef void (*BotFunc)(Galaxy*);

static void bot_random(Galaxy* g) {
    // count my planets
    int my_planets[MAX_PLANETS], my_cnt = 0;
    int all_planets[MAX_PLANETS], all_cnt = 0;
    for (int i = 0; i < g->item_count; i++) {
        if (g->items[i].type == OBJ_PLANET) {
            all_planets[all_cnt++] = i;
            if (g->items[i].owner == g->you)
                my_planets[my_cnt++] = i;
        }
    }
    if (my_cnt == 0 || all_cnt == 0) return;
    int src_idx = my_planets[rand() % my_cnt];
    int tgt_idx = all_planets[rand() % all_cnt];
    int pct = 5 + (rand() % 20) * 5; // 5..100 step 5
    char buf[64];
    snprintf(buf, sizeof(buf), "/SEND %d %d %d", pct,
             g->items[src_idx].id, g->items[tgt_idx].id);
    execute_command(g, buf);
}

static void bot_classic(Galaxy* g) {
    // from classic.lua: strongest planet (>=17 ships) -> best target
    int my_planets[MAX_PLANETS], my_cnt = 0;
    for (int i = 0; i < g->item_count; i++)
        if (g->items[i].type == OBJ_PLANET && g->items[i].owner == g->you)
            my_planets[my_cnt++] = i;
    if (my_cnt == 0) return;
    // find strongest
    int best_src = -1;
    double best_ships = 0;
    for (int i = 0; i < my_cnt; i++) {
        Item* p = &g->items[my_planets[i]];
        if (p->ships >= 17 && p->ships > best_ships) {
            best_ships = p->ships;
            best_src = my_planets[i];
        }
    }
    if (best_src == -1) return;
    // find best target (value = -ships + production - distance*0.2)
    int my_team = get_team(g, g->you);
    int winning = 0; // simplified – not used here
    double best_val = -1e9;
    int best_tgt = -1;
    for (int i = 0; i < g->item_count; i++) {
        Item* t = &g->items[i];
        if (t->type != OBJ_PLANET) continue;
        int t_team = get_team(g, t->owner);
        if (t_team == my_team) continue;
        if (winning && t_team == 0) continue;
        double dist = distance(g->items[best_src].x, g->items[best_src].y, t->x, t->y);
        double val = -t->ships + t->production - dist * 0.20;
        if (val > best_val) {
            best_val = val;
            best_tgt = i;
        }
    }
    if (best_tgt != -1) {
        char buf[64];
        snprintf(buf, sizeof(buf), "/SEND 65 %d %d",
                 g->items[best_src].id, g->items[best_tgt].id);
        execute_command(g, buf);
    }
}

// ----------------------------------------------------------------------
// Match runner (internal, no network)
// ----------------------------------------------------------------------
typedef struct {
    Galaxy g;
    BotFunc bot1, bot2;
    int    bot1_id, bot2_id;
    double total_time;
    int    winner; // 0 = draw, 1 = bot1, 2 = bot2
} Match;

static void init_galaxy(Galaxy* g, const char* map_file) {
    // Create a simple default map: 3 planets
    // For production, use the standard Galcon starter map
    g->item_count = 0;
    g->you = 0;
    g->time = 0.0;
    g->next_production = PRODUCTION_INTERVAL;
    // Create two users: bot1 (id=1) and bot2 (id=2)
    Item* u1 = &g->items[g->item_count++];
    u1->id = 1; u1->type = OBJ_USER; u1->team = 1; strcpy(u1->name, "bot1");
    Item* u2 = &g->items[g->item_count++];
    u2->id = 2; u2->type = OBJ_USER; u2->team = 2; strcpy(u2->name, "bot2");

    // Planets: each with id 101,102,103
    // Planet 1: owned by bot1, 30 ships, production 2
    Item* p1 = &g->items[g->item_count++];
    p1->id = 101; p1->type = OBJ_PLANET; p1->owner = 1; p1->ships = 30;
    p1->x = 100; p1->y = 100; p1->production = 2; p1->radius = 20;
    // Planet 2: owned by bot2, 30 ships, production 2
    Item* p2 = &g->items[g->item_count++];
    p2->id = 102; p2->type = OBJ_PLANET; p2->owner = 2; p2->ships = 30;
    p2->x = 400; p2->y = 300; p2->production = 2; p2->radius = 20;
    // Planet 3: neutral, 20 ships, production 1
    Item* p3 = &g->items[g->item_count++];
    p3->id = 103; p3->type = OBJ_PLANET; p3->owner = 0; p3->ships = 20;
    p3->x = 250; p3->y = 200; p3->production = 1; p3->radius = 15;
}

static int check_winner(Galaxy* g) {
    int team_ships[3] = {0,0,0}; // team 0,1,2
    for (int i = 0; i < g->item_count; i++) {
        if (g->items[i].type == OBJ_PLANET) {
            int t = get_team(g, g->items[i].owner);
            team_ships[t] += g->items[i].ships;
        } else if (g->items[i].type == OBJ_FLEET) {
            int t = get_team(g, g->items[i].owner);
            team_ships[t] += g->items[i].ships;
        }
    }
    if (team_ships[1] == 0 && team_ships[2] == 0) return 0; // draw
    if (team_ships[1] == 0) return 2;
    if (team_ships[2] == 0) return 1;
    return 0;
}

static void run_match(Match* m, double max_time) {
    init_galaxy(&m->g, NULL);
    m->g.you = 1; // for bot1's perspective – but commands use owner checks
    m->total_time = 0;
    double dt = TICK_DURATION;
    int ticks = 0;
    int winner = 0;
    while (m->total_time < max_time) {
        // let bot1 act (if it has planets)
        if (m->bot1) {
            int old_you = m->g.you;
            m->g.you = 1;
            m->bot1(&m->g);
            m->g.you = old_you;
        }
        // let bot2 act
        if (m->bot2) {
            int old_you = m->g.you;
            m->g.you = 2;
            m->bot2(&m->g);
            m->g.you = old_you;
        }
        run_tick(&m->g, dt);
        m->total_time += dt;
        ticks++;
        winner = check_winner(&m->g);
        if (winner != 0) break;
    }
    m->winner = winner;
}

// ----------------------------------------------------------------------
// Statistics test (internal)
// ----------------------------------------------------------------------
static void test_bots(const char* name1, BotFunc bot1, const char* name2, BotFunc bot2, int matches) {
    srand(time(NULL));
    int wins1 = 0, wins2 = 0, draws = 0;
    double total_time = 0;
    for (int i = 0; i < matches; i++) {
        Match m = {0};
        m.bot1 = bot1;
        m.bot2 = bot2;
        run_match(&m, 300.0); // 5 minutes max
        total_time += m.total_time;
        if (m.winner == 1) wins1++;
        else if (m.winner == 2) wins2++;
        else draws++;
        if ((i+1) % 100 == 0)
            printf("Progress: %d matches done\n", i+1);
    }
    printf("\n=== RESULTS ===\n");
    printf("%s wins: %d (%.1f%%)\n", name1, wins1, 100.0*wins1/matches);
    printf("%s wins: %d (%.1f%%)\n", name2, wins2, 100.0*wins2/matches);
    printf("Draws: %d (%.1f%%)\n", draws, 100.0*draws/matches);
    printf("Average match length: %.2f seconds\n", total_time/matches);
}

// ----------------------------------------------------------------------
// Network server (accepts bot connections)
// ----------------------------------------------------------------------
static int server_socket;
static volatile int server_running = 1;

static void* handle_client(void* arg) {
    int client_fd = *(int*)arg;
    free(arg);
    char buf[MAX_LINE];
    FILE* stream = fdopen(client_fd, "r+");
    if (!stream) {
        close(client_fd);
        return NULL;
    }
    // Each client gets its own Galaxy instance (one match)
    Galaxy g;
    memset(&g, 0, sizeof(g));
    init_galaxy(&g, NULL);
    g.you = 0; // will be set by /SET YOU

    while (server_running && fgets(buf, sizeof(buf), stream)) {
        buf[strcspn(buf, "\n")] = 0;
        if (strncmp(buf, "/SET YOU", 8) == 0) {
            int id;
            if (sscanf(buf, "/SET YOU %d", &id) == 1)
                g.you = id;
        } else if (strcmp(buf, "/TICK") == 0) {
            run_tick(&g, TICK_DURATION);
            fprintf(stream, "/TOCK\n");
            fflush(stream);
        } else {
            execute_command(&g, buf);
        }
    }
    fclose(stream);
    return NULL;
}

static void run_server(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { perror("socket"); exit(1); }
    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); exit(1);
    }
    listen(sock, 10);
    printf("Server listening on port %d\n", port);
    server_socket = sock;
    while (server_running) {
        int* client_fd = malloc(sizeof(int));
        *client_fd = accept(sock, NULL, NULL);
        if (*client_fd < 0) { free(client_fd); continue; }
        pthread_t tid;
        pthread_create(&tid, NULL, handle_client, client_fd);
        pthread_detach(tid);
    }
    close(sock);
}

// ----------------------------------------------------------------------
// Simple client (connects to server and runs a bot)
// ----------------------------------------------------------------------
static void run_client(const char* host, int port, BotFunc bot) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct hostent* he = gethostbyname(host);
    if (!he) { perror("gethostbyname"); exit(1); }
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect"); exit(1);
    }
    FILE* stream = fdopen(sock, "r+");
    if (!stream) { close(sock); exit(1); }
    // send /SET YOU ...
    fprintf(stream, "/SET YOU %d\n", 1); // assume bot gets id 1
    fflush(stream);
    char buf[MAX_LINE];
    Galaxy g;
    memset(&g, 0, sizeof(g));
    init_galaxy(&g, NULL);
    g.you = 1;
    while (fgets(buf, sizeof(buf), stream)) {
        buf[strcspn(buf, "\n")] = 0;
        if (strcmp(buf, "/TICK") == 0) {
            if (bot) bot(&g);
            fprintf(stream, "/TOCK\n");
            fflush(stream);
        } else if (strncmp(buf, "/SET YOU", 8) == 0) {
            // ignore, we already set
        } else {
            execute_command(&g, buf);
        }
    }
    fclose(stream);
}

// ----------------------------------------------------------------------
// Main entry point
// ----------------------------------------------------------------------
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage:\n");
        fprintf(stderr, "  %s server [port]            – start game server\n", argv[0]);
        fprintf(stderr, "  %s client <host> <port>     – connect bot to server\n", argv[0]);
        fprintf(stderr, "  %s test <bot1> <bot2> <matches> – internal stats\n", argv[0]);
        fprintf(stderr, "Bots: random, classic\n");
        return 1;
    }
    if (strcmp(argv[1], "server") == 0) {
        int port = (argc >= 3) ? atoi(argv[2]) : 2600;
        run_server(port);
    } else if (strcmp(argv[1], "client") == 0) {
        if (argc < 4) { fprintf(stderr, "Need host and port\n"); return 1; }
        const char* host = argv[2];
        int port = atoi(argv[3]);
        // choose which bot to run (hardcoded to classic for demo)
        run_client(host, port, bot_classic);
    } else if (strcmp(argv[1], "test") == 0) {
        if (argc < 5) { fprintf(stderr, "Need bot1 bot2 matches\n"); return 1; }
        const char* bot1_name = argv[2];
        const char* bot2_name = argv[3];
        int matches = atoi(argv[4]);
        BotFunc b1 = NULL, b2 = NULL;
        if (strcmp(bot1_name, "random") == 0) b1 = bot_random;
        else if (strcmp(bot1_name, "classic") == 0) b1 = bot_classic;
        if (strcmp(bot2_name, "random") == 0) b2 = bot_random;
        else if (strcmp(bot2_name, "classic") == 0) b2 = bot_classic;
        if (!b1 || !b2) {
            fprintf(stderr, "Unknown bot. Use 'random' or 'classic'\n");
            return 1;
        }
        test_bots(bot1_name, b1, bot2_name, b2, matches);
    } else {
        fprintf(stderr, "Unknown command\n");
        return 1;
    }
    return 0;
}
